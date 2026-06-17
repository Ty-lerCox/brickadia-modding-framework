use anyhow::{bail, Context, Result};
use std::ffi::OsString;
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, Write};
use std::mem::size_of;
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use std::net::TcpListener;
use std::{ptr, sync::PoisonError};
use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::System::Console::{
    AllocConsole, FreeConsole, GetConsoleWindow, SetConsoleTitleW, WriteConsoleInputW,
    INPUT_RECORD, INPUT_RECORD_0, KEY_EVENT, KEY_EVENT_RECORD, KEY_EVENT_RECORD_0,
    LEFT_ALT_PRESSED, LEFT_CTRL_PRESSED, SHIFT_PRESSED,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    MapVirtualKeyW, SendInput, VkKeyScanW, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT,
    KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, MAPVK_VK_TO_VSC, VK_CONTROL, VK_MENU, VK_RETURN,
    VK_SHIFT,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, GetForegroundWindow, SetForegroundWindow, ShowWindow, SW_HIDE, SW_SHOW,
};

const FORCE_KILL_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug)]
struct BridgeArgs {
    cwd: Option<OsString>,
    control_port: Option<u16>,
    command: OsString,
    args: Vec<OsString>,
}

fn parse_args() -> Result<BridgeArgs> {
    let mut args = std::env::args_os().skip(1);
    let mut cwd = None;
    let mut control_port = None;

    while let Some(arg) = args.next() {
        if arg == "--cwd" {
            let dir = args
                .next()
                .context("missing value for --cwd when launching console bridge")?;
            cwd = Some(dir);
            continue;
        }

        if arg == "--control-port" {
            let port = args
                .next()
                .context("missing value for --control-port when launching console bridge")?;
            let port = port
                .to_string_lossy()
                .parse::<u16>()
                .context("invalid --control-port value when launching console bridge")?;
            control_port = Some(port);
            continue;
        }

        if arg == "--" {
            let command = args
                .next()
                .context("missing child command after -- when launching console bridge")?;
            let args = args.collect();
            return Ok(BridgeArgs {
                cwd,
                control_port,
                command,
                args,
            });
        }

        bail!(
            "unexpected argument {:?}; expected --cwd <dir>, --control-port <port>, or --",
            arg
        );
    }

    bail!(
        "usage: omegga-console-bridge [--cwd <dir>] [--control-port <port>] -- <command> [args...]"
    );
}

fn request_shutdown(
    console_input: &Arc<Mutex<File>>,
    shutdown_requested: &Arc<AtomicBool>,
) {
    if shutdown_requested.swap(true, Ordering::SeqCst) {
        return;
    }

    let _ = inject_line(console_input, "exit");
}

fn spawn_force_kill_timer(
    child: Arc<Mutex<Child>>,
    shutdown_requested: Arc<AtomicBool>,
) {
    thread::spawn(move || {
        thread::sleep(FORCE_KILL_TIMEOUT);
        if shutdown_requested.load(Ordering::SeqCst) {
            let _ = child.lock().ok().and_then(|mut child| child.kill().ok());
        }
    });
}

fn ensure_hidden_console() -> Result<File> {
    unsafe {
        FreeConsole();
    }

    let ok = unsafe { AllocConsole() };
    if ok == 0 {
        return Err(std::io::Error::last_os_error()).context("failed to allocate hidden console");
    }

    let title = bridge_console_title();
    let mut wide_title = title.encode_utf16().collect::<Vec<u16>>();
    wide_title.push(0);
    let title_ok = unsafe { SetConsoleTitleW(wide_title.as_ptr()) };
    if title_ok == 0 {
        return Err(std::io::Error::last_os_error()).context("failed to set bridge console title");
    }

    let keep_visible = std::env::var_os("OMEGGA_BRIDGE_KEEP_VISIBLE").is_some();
    let window = unsafe { GetConsoleWindow() };
    if window != ptr::null_mut() && !keep_visible {
        unsafe { ShowWindow(window, SW_HIDE) };
    }

    OpenOptions::new()
        .read(true)
        .write(true)
        .open("CONIN$")
        .context("failed to open console input device")
}

fn make_key_event(unicode_char: u16, key_down: bool, virtual_key_code: u16) -> INPUT_RECORD {
    let scan_code = if virtual_key_code == 0 {
        0
    } else {
        unsafe { MapVirtualKeyW(virtual_key_code as u32, MAPVK_VK_TO_VSC) as u16 }
    };

    INPUT_RECORD {
        EventType: KEY_EVENT as u16,
        Event: INPUT_RECORD_0 {
            KeyEvent: KEY_EVENT_RECORD {
                bKeyDown: if key_down { 1 } else { 0 },
                wRepeatCount: 1,
                wVirtualKeyCode: virtual_key_code,
                wVirtualScanCode: scan_code,
                uChar: KEY_EVENT_RECORD_0 {
                    UnicodeChar: unicode_char,
                },
                dwControlKeyState: 0,
            },
        },
    }
}

fn make_key_event_with_state(
    unicode_char: u16,
    key_down: bool,
    virtual_key_code: u16,
    control_state: u32,
) -> INPUT_RECORD {
    let mut event = make_key_event(unicode_char, key_down, virtual_key_code);
    event.Event.KeyEvent.dwControlKeyState = control_state;
    event
}

fn bridge_debug(message: impl AsRef<str>) {
    if let Some(path) = std::env::var_os("OMEGGA_BRIDGE_TRACE") {
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{}", message.as_ref());
        }
    }
    if std::env::var_os("OMEGGA_BRIDGE_DEBUG").is_some() {
        eprintln!("{}", message.as_ref());
    }
}

fn bridge_console_title() -> String {
    format!("Omegga Console Bridge {}", std::process::id())
}

fn append_modifier_events(records: &mut Vec<INPUT_RECORD>, modifiers: u8, key_down: bool) {
    let ordered_modifiers = [
        (0b010, VK_CONTROL, LEFT_CTRL_PRESSED),
        (0b100, VK_MENU, LEFT_ALT_PRESSED),
        (0b001, VK_SHIFT, SHIFT_PRESSED),
    ];

    for (mask, virtual_key, control_state) in ordered_modifiers {
        if modifiers & mask != 0 {
            records.push(make_key_event_with_state(
                0,
                key_down,
                virtual_key,
                if key_down { control_state } else { 0 },
            ));
        }
    }
}

fn append_character_events(records: &mut Vec<INPUT_RECORD>, character: u16) {
    let vk = unsafe { VkKeyScanW(character) };
    if vk == -1 {
        records.push(make_key_event(character, true, 0));
        records.push(make_key_event(character, false, 0));
        return;
    }

    let virtual_key = (vk as u16 & 0xff) as u16;
    let modifiers = ((vk as u16 >> 8) & 0xff) as u8;
    let control_state = (if modifiers & 0b001 != 0 {
        SHIFT_PRESSED
    } else {
        0
    }) | (if modifiers & 0b010 != 0 {
        LEFT_CTRL_PRESSED
    } else {
        0
    }) | (if modifiers & 0b100 != 0 {
        LEFT_ALT_PRESSED
    } else {
        0
    });

    append_modifier_events(records, modifiers, true);
    records.push(make_key_event_with_state(
        character,
        true,
        virtual_key,
        control_state,
    ));
    records.push(make_key_event_with_state(
        character,
        false,
        virtual_key,
        control_state,
    ));
    append_modifier_events(records, modifiers, false);
}

fn write_console_input(console_input: &Arc<Mutex<File>>, records: &[INPUT_RECORD]) -> Result<()> {
    if records.is_empty() {
        return Ok(());
    }

    let handle = console_input
        .lock()
        .map_err(|_: PoisonError<_>| anyhow::anyhow!("failed to lock console input handle"))?
        .as_raw_handle() as HANDLE;
    let mut written = 0;
    let ok = unsafe {
        WriteConsoleInputW(
            handle,
            records.as_ptr(),
            records.len() as u32,
            &mut written,
        )
    };

    if ok == 0 {
        return Err(std::io::Error::last_os_error())
            .context("failed to write console input records");
    }

    if written != records.len() as u32 {
        bail!(
            "console input write was incomplete: wrote {} of {} records",
            written,
            records.len()
        );
    }

    Ok(())
}

fn make_keyboard_input(unicode_char: u16, flags: u32) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: if unicode_char == '\r' as u16 {
                    VK_RETURN as u16
                } else {
                    0
                },
                wScan: if unicode_char == '\r' as u16 {
                    0
                } else {
                    unicode_char
                },
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

fn get_sendkeys_script_path() -> Result<PathBuf> {
    let exe_dir = std::env::current_exe()
        .context("failed to resolve console bridge executable path")?
        .parent()
        .context("console bridge executable did not have a parent directory")?
        .to_path_buf();
    let script_path = exe_dir.join("..").join("..").join("windows-sendkeys.ps1");
    let script_path = Path::new(&script_path)
        .canonicalize()
        .context("failed to resolve windows-sendkeys.ps1 path")?;
    if !script_path.exists() {
        bail!("windows-sendkeys.ps1 was not found at {:?}", script_path);
    }
    Ok(script_path)
}

fn send_keys_with_powershell(line: &str) -> Result<()> {
    let script_path = get_sendkeys_script_path()?;
    let output = Command::new("powershell.exe")
        .args([
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(&script_path)
        .args([
            "-TargetPid",
            &std::process::id().to_string(),
            "-WindowTitle",
            &bridge_console_title(),
            "-Text",
            line,
        ])
        .arg("-PressEnter")
        .output()
        .context("failed to launch windows sendkeys helper")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        bail!(
            "windows sendkeys helper failed: {}",
            if !stderr.is_empty() {
                stderr
            } else if !stdout.is_empty() {
                stdout
            } else {
                format!("exit code {:?}", output.status.code())
            }
        );
    }

    Ok(())
}

fn set_foreground_window(window: *mut core::ffi::c_void) -> bool {
    let result = unsafe {
        ShowWindow(window, SW_SHOW);
        BringWindowToTop(window);
        SetForegroundWindow(window);
        GetForegroundWindow() == window
    };

    result
}

fn send_console_window_keys(line: &str) -> Result<()> {
    let window = unsafe { GetConsoleWindow() };
    if window == ptr::null_mut() {
        bail!("console window handle was null while sending keystrokes");
    }

    let previous_window = unsafe { GetForegroundWindow() };
    let foreground_ok = set_foreground_window(window);
    bridge_debug(format!(
        "bridge sendinput focus target={window:p} previous={previous_window:p} foreground_ok={foreground_ok}"
    ));
    thread::sleep(Duration::from_millis(50));

    let mut inputs = Vec::with_capacity(line.encode_utf16().count() * 2 + 2);
    for character in line.encode_utf16() {
        inputs.push(make_keyboard_input(character, KEYEVENTF_UNICODE));
        inputs.push(make_keyboard_input(
            character,
            KEYEVENTF_UNICODE | KEYEVENTF_KEYUP,
        ));
    }
    inputs.push(make_keyboard_input('\r' as u16, 0));
    inputs.push(make_keyboard_input('\r' as u16, KEYEVENTF_KEYUP));

    let sent = unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), size_of::<INPUT>() as i32) };
    bridge_debug(format!(
        "bridge sendinput count={} sent={}",
        inputs.len(),
        sent
    ));
    if sent != inputs.len() as u32 {
        unsafe {
            ShowWindow(window, SW_HIDE);
            if previous_window != ptr::null_mut() {
                SetForegroundWindow(previous_window);
            }
        }
        return Err(std::io::Error::last_os_error()).context("failed to send keyboard input");
    }

    thread::sleep(Duration::from_millis(50));
    let keep_visible = std::env::var_os("OMEGGA_BRIDGE_KEEP_VISIBLE").is_some();
    unsafe {
        if !keep_visible {
            ShowWindow(window, SW_HIDE);
        }
    }
    if previous_window != ptr::null_mut() && !keep_visible {
        let _ = set_foreground_window(previous_window);
    }

    Ok(())
}

fn inject_line(console_input: &Arc<Mutex<File>>, line: &str) -> Result<()> {
    if std::env::var_os("OMEGGA_BRIDGE_SENDKEYS").is_some() {
        let result = send_keys_with_powershell(line);
        bridge_debug(format!("bridge sendkeys {:?} -> {}", line, result.is_ok()));
        return result;
    }

    if std::env::var_os("OMEGGA_BRIDGE_SENDINPUT").is_some() {
        let result = send_console_window_keys(line);
        bridge_debug(format!("bridge sendinput {:?} -> {}", line, result.is_ok()));
        return result;
    }

    let mut records = Vec::with_capacity(line.encode_utf16().count() * 2 + 2);

    for character in line.encode_utf16() {
        append_character_events(&mut records, character);
    }

    records.push(make_key_event('\r' as u16, true, VK_RETURN));
    records.push(make_key_event('\r' as u16, false, VK_RETURN));

    let result = write_console_input(console_input, &records);
    if std::env::var_os("OMEGGA_BRIDGE_DEBUG").is_some() {
        eprintln!("bridge inject {:?} -> {}", line, result.is_ok());
    }
    result
}

fn spawn_control_server(
    port: u16,
    console_input: Arc<Mutex<File>>,
    shutdown_requested: Arc<AtomicBool>,
    child: Arc<Mutex<Child>>,
) {
    thread::spawn(move || {
        let listener = match TcpListener::bind(("127.0.0.1", port)) {
            Ok(listener) => listener,
            Err(error) => {
                eprintln!("failed to bind bridge control port {}: {}", port, error);
                request_shutdown(&console_input, &shutdown_requested);
                spawn_force_kill_timer(Arc::clone(&child), Arc::clone(&shutdown_requested));
                return;
            }
        };
        bridge_debug(format!("bridge listening on 127.0.0.1:{port}"));

        let (stream, _) = match listener.accept() {
            Ok(connection) => connection,
            Err(error) => {
                eprintln!("failed to accept bridge control connection: {}", error);
                request_shutdown(&console_input, &shutdown_requested);
                spawn_force_kill_timer(Arc::clone(&child), Arc::clone(&shutdown_requested));
                return;
            }
        };
        bridge_debug("bridge control connection accepted");

        let mut reader = io::BufReader::new(stream);
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => {
                    request_shutdown(&console_input, &shutdown_requested);
                    spawn_force_kill_timer(
                        Arc::clone(&child),
                        Arc::clone(&shutdown_requested),
                    );
                    break;
                }
                Ok(_) => {
                    while line.ends_with('\n') || line.ends_with('\r') {
                        line.pop();
                    }
                    bridge_debug(format!("bridge control line {:?}", line));
                    if inject_line(&console_input, &line).is_err() {
                        request_shutdown(&console_input, &shutdown_requested);
                        spawn_force_kill_timer(
                            Arc::clone(&child),
                            Arc::clone(&shutdown_requested),
                        );
                        break;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    request_shutdown(&console_input, &shutdown_requested);
                    spawn_force_kill_timer(
                        Arc::clone(&child),
                        Arc::clone(&shutdown_requested),
                    );
                    break;
                }
            }
        }
    });
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args = parse_args()?;
    let console_input = Arc::new(Mutex::new(ensure_hidden_console()?));
    let child_stdin = console_input
        .lock()
        .map_err(|_: PoisonError<_>| anyhow::anyhow!("failed to lock console input for child stdin"))?
        .try_clone()
        .context("failed to clone console input handle for child stdin")?;
    let mut command = Command::new(&args.command);
    command.args(&args.args);
    command.stdin(Stdio::from(child_stdin));
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    if let Some(cwd) = args.cwd {
        command.current_dir(cwd);
    }

    let mut child = command
        .spawn()
        .with_context(|| format!("failed to spawn child process {:?}", args.command))?;
    let child_stdout = child.stdout.take().context("failed to capture child stdout")?;
    let child_stderr = child.stderr.take().context("failed to capture child stderr")?;
    let child = Arc::new(Mutex::new(child));
    let shutdown_requested = Arc::new(AtomicBool::new(false));

    if let Some(port) = args.control_port {
        spawn_control_server(
            port,
            Arc::clone(&console_input),
            Arc::clone(&shutdown_requested),
            Arc::clone(&child),
        );
    }

    {
        let console_input = Arc::clone(&console_input);
        let shutdown_requested = Arc::clone(&shutdown_requested);
        let child = Arc::clone(&child);
        ctrlc::set_handler(move || {
            request_shutdown(&console_input, &shutdown_requested);
            spawn_force_kill_timer(
                Arc::clone(&child),
                Arc::clone(&shutdown_requested),
            );
        })
        .context("failed to register console bridge Ctrl+C handler")?;
    }

    thread::spawn(move || {
        let stdout = io::stdout();
        let mut stdout = stdout.lock();
        let mut child_stdout = child_stdout;
        let _ = io::copy(&mut child_stdout, &mut stdout);
        let _ = stdout.flush();
    });

    thread::spawn(move || {
        let stderr = io::stderr();
        let mut stderr = stderr.lock();
        let mut child_stderr = child_stderr;
        let _ = io::copy(&mut child_stderr, &mut stderr);
        let _ = stderr.flush();
    });
    let exit_code: i32 = loop {
        let status = child
            .lock()
            .map_err(|_: PoisonError<_>| anyhow::anyhow!("failed to lock child process while waiting"))?
            .try_wait()
            .context("failed while polling bridged child process")?;
        if let Some(status) = status {
            break status.code().unwrap_or(1);
        }

        thread::sleep(Duration::from_millis(100));
    };

    std::process::exit(exit_code);
}
