#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <atomic>
#include <cctype>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

const wchar_t* kControlPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\minigame-event-watcher-control.txt";
const wchar_t* kStatusPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\minigame-event-watcher-status.txt";
const wchar_t* kLogPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\minigame-event-watcher.log";
const wchar_t* kEventPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\minigame-event-watcher-events.tsv";

using NativeFunc = void(__fastcall*)(void* context, void* stack, void* result);

std::atomic<bool> g_enabled{true};
std::atomic<bool> g_trace{true};
std::atomic<bool> g_installed{false};
std::atomic<uintptr_t> g_function{0};
std::atomic<uint32_t> g_func_offset{0xD8};
std::atomic<uint32_t> g_locals_offset{0x28};
std::atomic<uint32_t> g_scan_bytes{0x120};
std::atomic<uint64_t> g_hits{0};
std::atomic<uint64_t> g_events{0};
std::atomic<uint64_t> g_param_read_failures{0};
std::atomic<uint64_t> g_text_misses{0};

void** g_func_slot = nullptr;
NativeFunc g_original = nullptr;

void __fastcall NativeFuncDetour(void* context, void* stack, void* result);

void ensure_parent(const wchar_t* path) {
    wchar_t buffer[MAX_PATH * 2]{};
    wcsncpy_s(buffer, path, _TRUNCATE);
    wchar_t* slash = wcsrchr(buffer, L'\\');
    if (!slash) {
        return;
    }
    *slash = L'\0';
    CreateDirectoryW(buffer, nullptr);
}

void append_text(const wchar_t* path, const char* fmt, ...) {
    ensure_parent(path);
    FILE* file = nullptr;
    _wfopen_s(&file, path, L"ab");
    if (!file) {
        return;
    }

    va_list args;
    va_start(args, fmt);
    std::vfprintf(file, fmt, args);
    va_end(args);
    std::fclose(file);
}

void append_log(const char* fmt, ...) {
    ensure_parent(kLogPath);
    FILE* file = nullptr;
    _wfopen_s(&file, kLogPath, L"ab");
    if (!file) {
        return;
    }

    SYSTEMTIME st{};
    GetLocalTime(&st);
    std::fprintf(
        file,
        "%04u-%02u-%02u %02u:%02u:%02u.%03u ",
        st.wYear,
        st.wMonth,
        st.wDay,
        st.wHour,
        st.wMinute,
        st.wSecond,
        st.wMilliseconds);

    va_list args;
    va_start(args, fmt);
    std::vfprintf(file, fmt, args);
    va_end(args);
    std::fprintf(file, "\n");
    std::fclose(file);
}

std::string trim_ascii(const std::string& value) {
    size_t first = 0;
    while (first < value.size() && std::isspace(static_cast<unsigned char>(value[first]))) {
        ++first;
    }
    size_t last = value.size();
    while (last > first && std::isspace(static_cast<unsigned char>(value[last - 1]))) {
        --last;
    }
    return value.substr(first, last - first);
}

std::string read_text_file(const wchar_t* path) {
    FILE* file = nullptr;
    _wfopen_s(&file, path, L"rb");
    if (!file) {
        return {};
    }
    std::fseek(file, 0, SEEK_END);
    long size = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    if (size <= 0 || size > 1024 * 1024) {
        std::fclose(file);
        return {};
    }
    std::string text;
    text.resize(static_cast<size_t>(size));
    std::fread(text.data(), 1, text.size(), file);
    std::fclose(file);
    return text;
}

uintptr_t parse_numeric_literal(const char* text) {
    if (!text) {
        return 0;
    }
    while (*text == ' ' || *text == '\t') {
        ++text;
    }
    int base = 10;
    if (text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
        base = 16;
        text += 2;
    }
    char* end = nullptr;
    uintptr_t value = static_cast<uintptr_t>(_strtoui64(text, &end, base));
    return end == text ? 0 : value;
}

uintptr_t parse_hex_value(const std::string& text, const char* key, uintptr_t fallback = 0) {
    const std::string prefix = std::string(key) + "=";
    size_t pos = text.find(prefix);
    if (pos == std::string::npos) {
        return fallback;
    }
    pos += prefix.size();
    uintptr_t value = parse_numeric_literal(text.c_str() + pos);
    return value == 0 ? fallback : value;
}

bool parse_bool_value(const std::string& text, const char* key, bool fallback) {
    const std::string prefix = std::string(key) + "=";
    size_t pos = text.find(prefix);
    if (pos == std::string::npos) {
        return fallback;
    }
    pos += prefix.size();
    while (pos < text.size() && (text[pos] == ' ' || text[pos] == '\t')) {
        ++pos;
    }
    return text.compare(pos, 1, "1") == 0 ||
        text.compare(pos, 4, "true") == 0 ||
        text.compare(pos, 3, "yes") == 0 ||
        text.compare(pos, 2, "on") == 0;
}

bool is_accessible_memory(uintptr_t address, size_t bytes) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (address == 0 || bytes == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0) {
        return false;
    }
    if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS)) {
        return false;
    }
    uintptr_t region_end = reinterpret_cast<uintptr_t>(mbi.BaseAddress) + mbi.RegionSize;
    if (address + bytes < address || address + bytes > region_end) {
        return false;
    }
    const DWORD writable_or_readable =
        PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
        PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    return (mbi.Protect & writable_or_readable) != 0;
}

bool read_u64(uintptr_t address, uintptr_t* out) {
    if (!out || !is_accessible_memory(address, sizeof(uintptr_t))) {
        return false;
    }
    __try {
        std::memcpy(out, reinterpret_cast<void*>(address), sizeof(uintptr_t));
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool read_i32(uintptr_t address, int32_t* out) {
    if (!out || !is_accessible_memory(address, sizeof(int32_t))) {
        return false;
    }
    __try {
        std::memcpy(out, reinterpret_cast<void*>(address), sizeof(int32_t));
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool read_utf16_string(uintptr_t address, int32_t length, std::string* out) {
    if (!out || address == 0 || length <= 0 || length > 512) {
        return false;
    }
    size_t bytes = static_cast<size_t>(length) * sizeof(wchar_t);
    if (!is_accessible_memory(address, bytes)) {
        return false;
    }

    std::string text;
    text.reserve(static_cast<size_t>(length));
    const wchar_t* chars = reinterpret_cast<const wchar_t*>(address);
    for (int32_t index = 0; index < length; ++index) {
        wchar_t ch = chars[index];
        if (ch == 0) {
            break;
        }
        if (ch < 0x20 || ch > 0x7e) {
            return false;
        }
        text.push_back(static_cast<char>(ch));
    }
    text = trim_ascii(text);
    if (text.empty()) {
        return false;
    }
    *out = text;
    return true;
}

bool read_ansi_string(uintptr_t address, int32_t length, std::string* out) {
    if (!out || address == 0 || length <= 0 || length > 512) {
        return false;
    }
    if (!is_accessible_memory(address, static_cast<size_t>(length))) {
        return false;
    }

    std::string text;
    text.reserve(static_cast<size_t>(length));
    const char* chars = reinterpret_cast<const char*>(address);
    for (int32_t index = 0; index < length; ++index) {
        unsigned char ch = static_cast<unsigned char>(chars[index]);
        if (ch == 0) {
            break;
        }
        if (ch < 0x20 || ch > 0x7e) {
            return false;
        }
        text.push_back(static_cast<char>(ch));
    }
    text = trim_ascii(text);
    if (text.empty()) {
        return false;
    }
    *out = text;
    return true;
}

void push_candidate(std::vector<std::string>* candidates, const std::string& value) {
    if (!candidates) {
        return;
    }
    std::string text = trim_ascii(value);
    if (text.empty()) {
        return;
    }
    for (const std::string& existing : *candidates) {
        if (existing == text) {
            return;
        }
    }
    candidates->push_back(text);
}

void scan_fstring_like(uintptr_t base, uint32_t bytes, std::vector<std::string>* candidates) {
    if (base == 0 || bytes < 16 || !is_accessible_memory(base, bytes)) {
        return;
    }
    const uint32_t max_offset = bytes > 16 ? bytes - 16 : 0;
    for (uint32_t offset = 0; offset <= max_offset; offset += 4) {
        uintptr_t data_ptr = 0;
        int32_t len = 0;
        int32_t max = 0;
        if (!read_u64(base + offset, &data_ptr) ||
            !read_i32(base + offset + 8, &len) ||
            !read_i32(base + offset + 12, &max)) {
            continue;
        }
        if (len <= 0 || len > 512 || max < len || max > 4096 || data_ptr == 0) {
            continue;
        }

        std::string text;
        if (read_utf16_string(data_ptr, len, &text) || read_ansi_string(data_ptr, len, &text)) {
            push_candidate(candidates, text);
        }
    }
}

void scan_direct_strings(uintptr_t base, uint32_t bytes, std::vector<std::string>* candidates) {
    if (base == 0 || bytes == 0 || !is_accessible_memory(base, bytes)) {
        return;
    }
    const uint32_t limit = bytes > 0x400 ? 0x400 : bytes;
    for (uint32_t offset = 0; offset < limit; ++offset) {
        std::string text;
        if (read_utf16_string(base + offset, 128, &text) || read_ansi_string(base + offset, 128, &text)) {
            push_candidate(candidates, text);
        }
    }
}

std::string join_candidates(const std::vector<std::string>& candidates) {
    std::string out;
    for (size_t index = 0; index < candidates.size(); ++index) {
        if (index > 0) {
            out += "|";
        }
        out += candidates[index];
    }
    return out;
}

bool read_notification_params(void* stack, uintptr_t* out_locals, uintptr_t values[9]) {
    if (!stack || !out_locals || !values) {
        return false;
    }
    uintptr_t locals = 0;
    __try {
        std::memcpy(&locals, static_cast<unsigned char*>(stack) + g_locals_offset.load(), sizeof(uintptr_t));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    if (locals == 0 || !is_accessible_memory(locals, 0x48)) {
        return false;
    }
    __try {
        std::memcpy(values, reinterpret_cast<void*>(locals), sizeof(uintptr_t) * 9);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    *out_locals = locals;
    return true;
}

void append_event(uint64_t event_id, void* context, void* stack, void* result, uintptr_t locals, uintptr_t values[9]) {
    SYSTEMTIME st{};
    GetSystemTime(&st);

    std::vector<std::string> p1_text;
    std::vector<std::string> p3_text;
    const uint32_t scan_bytes = g_scan_bytes.load();
    scan_fstring_like(locals + 0x0, 0x20, &p1_text);
    scan_fstring_like(locals + 0x8, 0x18, &p1_text);
    scan_fstring_like(locals + 0x28, 0x20, &p3_text);
    scan_fstring_like(locals + 0x30, 0x18, &p3_text);
    scan_fstring_like(values[0], scan_bytes, &p1_text);
    scan_fstring_like(values[5], scan_bytes, &p3_text);
    scan_direct_strings(values[0], scan_bytes, &p1_text);
    scan_direct_strings(values[5], scan_bytes, &p3_text);

    std::string p1_joined = join_candidates(p1_text);
    std::string p3_joined = join_candidates(p3_text);
    if (p1_joined.empty() && p3_joined.empty()) {
        g_text_misses.fetch_add(1);
    }

    append_text(
        kEventPath,
        "event=death_notification\tid=%llu\tutc=%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\tcontext=0x%p\tstack=0x%p\tresult=0x%p\tlocals=0x%p\tp1_object=0x%p\tp1_word1=0x%p\tp1_word2=0x%p\tp1_word3=0x%p\tparam2=0x%p\tp3_object=0x%p\tp3_word1=0x%p\tp3_word2=0x%p\tp3_word3=0x%p\tp1_text=%s\tp3_text=%s\n",
        static_cast<unsigned long long>(event_id),
        st.wYear,
        st.wMonth,
        st.wDay,
        st.wHour,
        st.wMinute,
        st.wSecond,
        st.wMilliseconds,
        context,
        stack,
        result,
        reinterpret_cast<void*>(locals),
        reinterpret_cast<void*>(values[0]),
        reinterpret_cast<void*>(values[1]),
        reinterpret_cast<void*>(values[2]),
        reinterpret_cast<void*>(values[3]),
        reinterpret_cast<void*>(values[4]),
        reinterpret_cast<void*>(values[5]),
        reinterpret_cast<void*>(values[6]),
        reinterpret_cast<void*>(values[7]),
        reinterpret_cast<void*>(values[8]),
        p1_joined.c_str(),
        p3_joined.c_str());
}

void write_status(const char* reason) {
    ensure_parent(kStatusPath);
    FILE* file = nullptr;
    _wfopen_s(&file, kStatusPath, L"wb");
    if (!file) {
        return;
    }
    std::fprintf(file, "installed=%d\n", g_installed.load() ? 1 : 0);
    std::fprintf(file, "enabled=%d\n", g_enabled.load() ? 1 : 0);
    std::fprintf(file, "trace=%d\n", g_trace.load() ? 1 : 0);
    std::fprintf(file, "function=0x%p\n", reinterpret_cast<void*>(g_function.load()));
    std::fprintf(file, "slot=0x%p\n", reinterpret_cast<void*>(g_func_slot));
    std::fprintf(file, "original=0x%p\n", reinterpret_cast<void*>(g_original));
    std::fprintf(file, "detour=0x%p\n", reinterpret_cast<void*>(&NativeFuncDetour));
    std::fprintf(file, "func_offset=0x%X\n", g_func_offset.load());
    std::fprintf(file, "locals_offset=0x%X\n", g_locals_offset.load());
    std::fprintf(file, "scan_bytes=0x%X\n", g_scan_bytes.load());
    std::fprintf(file, "hits=%llu\n", static_cast<unsigned long long>(g_hits.load()));
    std::fprintf(file, "events=%llu\n", static_cast<unsigned long long>(g_events.load()));
    std::fprintf(file, "param_read_failures=%llu\n", static_cast<unsigned long long>(g_param_read_failures.load()));
    std::fprintf(file, "text_misses=%llu\n", static_cast<unsigned long long>(g_text_misses.load()));
    std::fprintf(file, "event_path=C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\minigame-event-watcher-events.tsv\n");
    std::fprintf(file, "reason=%s\n", reason ? reason : "");
    std::fclose(file);
}

void load_control() {
    std::string text = read_text_file(kControlPath);
    g_function.store(parse_hex_value(text, "function", g_function.load()));
    g_func_offset.store(static_cast<uint32_t>(parse_hex_value(text, "func_offset", g_func_offset.load())));
    g_locals_offset.store(static_cast<uint32_t>(parse_hex_value(text, "locals_offset", g_locals_offset.load())));
    g_scan_bytes.store(static_cast<uint32_t>(parse_hex_value(text, "scan_bytes", g_scan_bytes.load())));
    g_enabled.store(parse_bool_value(text, "enabled", g_enabled.load()));
    g_trace.store(parse_bool_value(text, "trace", g_trace.load()));
}

bool install_hook() {
    load_control();
    uintptr_t function = g_function.load();
    if (function == 0) {
        append_log("install skipped missing function");
        write_status("missing-function");
        return false;
    }
    uintptr_t slot_address = function + g_func_offset.load();
    if (!is_accessible_memory(slot_address, sizeof(void*))) {
        append_log("install failed inaccessible slot function=0x%p slot=0x%p", reinterpret_cast<void*>(function), reinterpret_cast<void*>(slot_address));
        write_status("inaccessible-slot");
        return false;
    }

    void** slot = reinterpret_cast<void**>(slot_address);
    void* previous = InterlockedExchangePointer(slot, reinterpret_cast<void*>(&NativeFuncDetour));
    if (previous == reinterpret_cast<void*>(&NativeFuncDetour)) {
        g_func_slot = slot;
        g_installed.store(true);
        append_log("hook already installed function=0x%p slot=0x%p", reinterpret_cast<void*>(function), slot);
        write_status("already-installed");
        return true;
    }
    if (!previous) {
        append_log("install failed null original function=0x%p slot=0x%p", reinterpret_cast<void*>(function), slot);
        write_status("null-original");
        return false;
    }

    g_func_slot = slot;
    g_original = reinterpret_cast<NativeFunc>(previous);
    g_installed.store(true);
    append_log(
        "hook installed function=0x%p slot=0x%p original=0x%p detour=0x%p",
        reinterpret_cast<void*>(function),
        slot,
        previous,
        reinterpret_cast<void*>(&NativeFuncDetour));
    write_status("installed");
    return true;
}

void __fastcall NativeFuncDetour(void* context, void* stack, void* result) {
    const uint64_t hits = g_hits.fetch_add(1) + 1;

    uintptr_t locals = 0;
    uintptr_t values[9]{};
    bool params_ok = read_notification_params(stack, &locals, values);
    if (!params_ok) {
        g_param_read_failures.fetch_add(1);
    }

    if (g_enabled.load() && params_ok) {
        uint64_t event_id = g_events.fetch_add(1) + 1;
        append_event(event_id, context, stack, result, locals, values);
    }

    if (g_trace.load() && (hits <= 20 || !params_ok)) {
        append_log(
            "hit context=0x%p stack=0x%p result=0x%p locals=0x%p params_ok=%d hits=%llu events=%llu",
            context,
            stack,
            result,
            reinterpret_cast<void*>(locals),
            params_ok ? 1 : 0,
            static_cast<unsigned long long>(hits),
            static_cast<unsigned long long>(g_events.load()));
    }

    NativeFunc original = g_original;
    if (original) {
        original(context, stack, result);
    }
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        append_log("minigame event watcher loaded");
        install_hook();
    }
    return TRUE;
}
