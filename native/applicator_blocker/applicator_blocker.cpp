#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace {

const wchar_t* kControlPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\applicator-blocker-control.txt";
const wchar_t* kStatusPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\applicator-blocker-status.txt";
const wchar_t* kLogPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\applicator-blocker.log";
const wchar_t* kEventPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\applicator-blocker-events.tsv";

using ProcessEventFn = void(__fastcall*)(void* object, void* function, void* params);

std::atomic<bool> g_enabled{false};
std::atomic<bool> g_block{true};
std::atomic<bool> g_installed{false};
std::atomic<uintptr_t> g_context{0};
std::atomic<uintptr_t> g_function{0};
std::atomic<uintptr_t> g_denied_component{0};
std::atomic<uint32_t> g_slot_index{72};
std::atomic<uint64_t> g_hits{0};
std::atomic<uint64_t> g_blocks{0};
std::atomic<uint64_t> g_passthrough{0};
std::atomic<uint64_t> g_allowed_itemspawn{0};
std::atomic<uint64_t> g_allowed_context_overflow{0};

void** g_slot = nullptr;
uintptr_t g_vtable = 0;
ProcessEventFn g_original = nullptr;
SRWLOCK g_allowlist_lock = SRWLOCK_INIT;
uintptr_t g_allowed_contexts[256]{};
uint32_t g_allowed_context_count = 0;

void __fastcall ProcessEventDetour(void* object, void* function, void* params);

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

uintptr_t parse_hex_value(const std::string& text, const char* key, uintptr_t fallback = 0) {
    const std::string prefix = std::string(key) + "=";
    size_t pos = text.find(prefix);
    if (pos == std::string::npos) {
        return fallback;
    }
    pos += prefix.size();
    while (pos < text.size() && (text[pos] == ' ' || text[pos] == '\t')) {
        ++pos;
    }
    int base = 10;
    if (pos + 2 <= text.size() && text[pos] == '0' && (text[pos + 1] == 'x' || text[pos + 1] == 'X')) {
        base = 16;
        pos += 2;
    }
    char* end = nullptr;
    uintptr_t value = static_cast<uintptr_t>(_strtoui64(text.c_str() + pos, &end, base));
    return end == text.c_str() + pos ? fallback : value;
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

bool load_allowed_contexts(const std::string& text) {
    uintptr_t parsed[256]{};
    uint32_t count = 0;
    uint64_t overflow = 0;

    size_t start = 0;
    while (start <= text.size()) {
        size_t end = text.find_first_of("\r\n", start);
        size_t length = (end == std::string::npos) ? text.size() - start : end - start;
        std::string line = text.substr(start, length);
        size_t equals = line.find('=');
        if (equals != std::string::npos) {
            std::string key = line.substr(0, equals);
            while (!key.empty() && (key.back() == ' ' || key.back() == '\t')) {
                key.pop_back();
            }
            size_t key_start = 0;
            while (key_start < key.size() && (key[key_start] == ' ' || key[key_start] == '\t')) {
                ++key_start;
            }
            key = key.substr(key_start);
            if (key == "allowed_context" || key == "allow_context") {
                const uintptr_t value = parse_hex_value(line, key.c_str(), 0);
                if (value != 0) {
                    bool duplicate = false;
                    for (uint32_t index = 0; index < count; ++index) {
                        if (parsed[index] == value) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate) {
                        if (count < 256) {
                            parsed[count++] = value;
                        } else {
                            ++overflow;
                        }
                    }
                }
            }
        }

        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }

    bool changed = false;
    AcquireSRWLockExclusive(&g_allowlist_lock);
    if (g_allowed_context_count != count) {
        changed = true;
    } else {
        for (uint32_t index = 0; index < count; ++index) {
            if (g_allowed_contexts[index] != parsed[index]) {
                changed = true;
                break;
            }
        }
    }
    std::memset(g_allowed_contexts, 0, sizeof(g_allowed_contexts));
    std::memcpy(g_allowed_contexts, parsed, count * sizeof(uintptr_t));
    g_allowed_context_count = count;
    ReleaseSRWLockExclusive(&g_allowlist_lock);
    if (overflow > 0) {
        g_allowed_context_overflow.fetch_add(overflow);
    }
    return changed;
}

bool context_is_allowed(void* context) {
    const uintptr_t context_address = reinterpret_cast<uintptr_t>(context);
    if (context_address == 0) {
        return false;
    }

    bool allowed = false;
    AcquireSRWLockShared(&g_allowlist_lock);
    for (uint32_t index = 0; index < g_allowed_context_count; ++index) {
        if (g_allowed_contexts[index] == context_address) {
            allowed = true;
            break;
        }
    }
    ReleaseSRWLockShared(&g_allowlist_lock);
    return allowed;
}

bool is_accessible_memory(uintptr_t address, size_t bytes) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (address == 0 || bytes == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0) {
        return false;
    }
    if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS)) {
        return false;
    }
    const uintptr_t region_start = reinterpret_cast<uintptr_t>(mbi.BaseAddress);
    const uintptr_t region_end = region_start + mbi.RegionSize;
    return address >= region_start && address + bytes <= region_end;
}

bool is_executable_memory(uintptr_t address) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (address == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0) {
        return false;
    }
    if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS)) {
        return false;
    }
    const DWORD execute_flags =
        PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    return (mbi.Protect & execute_flags) != 0;
}

std::string read_text(const wchar_t* path) {
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

bool load_control() {
    const std::string text = read_text(kControlPath);
    if (text.empty()) {
        return false;
    }

    g_enabled.store(parse_bool_value(text, "enable", g_enabled.load()));
    g_block.store(parse_bool_value(text, "block", g_block.load()));
    g_context.store(parse_hex_value(text, "context", g_context.load()));
    g_function.store(parse_hex_value(text, "function", g_function.load()));
    g_denied_component.store(parse_hex_value(text, "denied_component", g_denied_component.load()));
    g_slot_index.store(static_cast<uint32_t>(parse_hex_value(text, "slot", g_slot_index.load())));
    return load_allowed_contexts(text);
}

void append_policy_event(
    const char* event_name,
    uint64_t id,
    void* context,
    void* function,
    void* params,
    uintptr_t component,
    const char* reason) {
    ensure_parent(kEventPath);
    FILE* file = nullptr;
    _wfopen_s(&file, kEventPath, L"ab");
    if (!file) {
        return;
    }

    SYSTEMTIME st{};
    GetSystemTime(&st);
    const char* id_key = (event_name && std::strcmp(event_name, "allow") == 0) ? "allow_id" : "block_id";
    std::fprintf(
        file,
        "event=%s\t%s=%llu\tutc=%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\tcontext=0x%p\tfunction=0x%p\tparams=0x%p\tcomponent=0x%p\treason=%s\n",
        event_name ? event_name : "",
        id_key,
        static_cast<unsigned long long>(id),
        st.wYear,
        st.wMonth,
        st.wDay,
        st.wHour,
        st.wMinute,
        st.wSecond,
        st.wMilliseconds,
        context,
        function,
        params,
        reinterpret_cast<void*>(component),
        reason ? reason : "");
    std::fclose(file);
}

void write_status(const char* reason) {
    ensure_parent(kStatusPath);
    FILE* file = nullptr;
    _wfopen_s(&file, kStatusPath, L"wb");
    if (!file) {
        return;
    }
    std::fprintf(file, "reason=%s\n", reason ? reason : "");
    std::fprintf(file, "installed=%d\n", g_installed.load() ? 1 : 0);
    std::fprintf(file, "enabled=%d\n", g_enabled.load() ? 1 : 0);
    std::fprintf(file, "block=%d\n", g_block.load() ? 1 : 0);
    std::fprintf(file, "context=0x%p\n", reinterpret_cast<void*>(g_context.load()));
    std::fprintf(file, "function=0x%p\n", reinterpret_cast<void*>(g_function.load()));
    std::fprintf(file, "denied_component=0x%p\n", reinterpret_cast<void*>(g_denied_component.load()));
    std::fprintf(file, "slot_index=%u\n", g_slot_index.load());
    std::fprintf(file, "vtable=0x%p\n", reinterpret_cast<void*>(g_vtable));
    std::fprintf(file, "slot=0x%p\n", reinterpret_cast<void*>(g_slot));
    std::fprintf(file, "original=0x%p\n", reinterpret_cast<void*>(g_original));
    std::fprintf(file, "detour=0x%p\n", reinterpret_cast<void*>(&ProcessEventDetour));
    std::fprintf(file, "hits=%llu\n", static_cast<unsigned long long>(g_hits.load()));
    std::fprintf(file, "blocks=%llu\n", static_cast<unsigned long long>(g_blocks.load()));
    std::fprintf(file, "allowed_itemspawn=%llu\n", static_cast<unsigned long long>(g_allowed_itemspawn.load()));
    std::fprintf(file, "passthrough=%llu\n", static_cast<unsigned long long>(g_passthrough.load()));
    std::fprintf(file, "event_path=C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\applicator-blocker-events.tsv\n");
    std::fprintf(file, "allowed_context_count=%u\n", g_allowed_context_count);
    for (uint32_t index = 0; index < g_allowed_context_count; ++index) {
        std::fprintf(
            file,
            "allowed_context_%u=0x%p\n",
            index + 1,
            reinterpret_cast<void*>(g_allowed_contexts[index]));
    }
    std::fprintf(file, "allowed_context_overflow=%llu\n", static_cast<unsigned long long>(g_allowed_context_overflow.load()));
    std::fclose(file);
}

bool read_component_param(void* params, uintptr_t* out_component) {
    if (!params || !out_component) {
        return false;
    }
    __try {
        std::memcpy(out_component, static_cast<unsigned char*>(params) + 8, sizeof(uintptr_t));
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

void __fastcall ProcessEventDetour(void* object, void* function, void* params) {
    g_hits.fetch_add(1);

    uintptr_t target_function = g_function.load();
    const uintptr_t denied_component = g_denied_component.load();
    if (g_enabled.load() &&
        denied_component != 0 &&
        (target_function == 0 || reinterpret_cast<uintptr_t>(function) == target_function)) {
        uintptr_t component = 0;
        if (read_component_param(params, &component) && component == denied_component) {
            if (target_function == 0) {
                target_function = reinterpret_cast<uintptr_t>(function);
                g_function.store(target_function);
                append_log(
                    "learned ServerAddComponent function=0x%p object=0x%p params=0x%p component=0x%p",
                    function,
                    object,
                    params,
                    reinterpret_cast<void*>(component));
            }
            if (context_is_allowed(object)) {
                const uint64_t allowed = g_allowed_itemspawn.fetch_add(1) + 1;
                append_policy_event("allow", allowed, object, function, params, component, "ContextAllowlisted");
                append_log(
                    "allowed ServerAddComponent object=0x%p function=0x%p params=0x%p component=0x%p allowed_itemspawn=%llu",
                    object,
                    function,
                    params,
                    reinterpret_cast<void*>(component),
                    static_cast<unsigned long long>(allowed));
                write_status("allowed");
                g_passthrough.fetch_add(1);
                if (g_original) {
                    g_original(object, function, params);
                }
                return;
            }
            if (g_block.load()) {
                const uint64_t blocks = g_blocks.fetch_add(1) + 1;
                append_policy_event("block", blocks, object, function, params, component, "ItemSpawnDenied");
                append_log(
                    "blocked ServerAddComponent object=0x%p function=0x%p params=0x%p component=0x%p blocks=%llu",
                    object,
                    function,
                    params,
                    reinterpret_cast<void*>(component),
                    static_cast<unsigned long long>(blocks));
                write_status("blocked");
                return;
            }
        }
    }

    g_passthrough.fetch_add(1);
    if (g_original) {
        g_original(object, function, params);
    }
}

bool install_hook() {
    load_control();

    const uintptr_t context = g_context.load();
    const uint32_t slot_index = g_slot_index.load();
    if (context == 0 || slot_index > 512) {
        append_log("install skipped context=0x%p slot=%u", reinterpret_cast<void*>(context), slot_index);
        write_status("missing-context");
        return false;
    }

    if (!is_accessible_memory(context, sizeof(uintptr_t))) {
        append_log("install failed inaccessible context=0x%p", reinterpret_cast<void*>(context));
        write_status("context-inaccessible");
        return false;
    }

    uintptr_t vtable = 0;
    __try {
        std::memcpy(&vtable, reinterpret_cast<void*>(context), sizeof(vtable));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        append_log("install failed reading vtable context=0x%p", reinterpret_cast<void*>(context));
        write_status("vtable-read-failed");
        return false;
    }

    if (vtable == 0) {
        append_log("install failed empty vtable context=0x%p", reinterpret_cast<void*>(context));
        write_status("empty-vtable");
        return false;
    }

    const uintptr_t slot_address = vtable + static_cast<uintptr_t>(slot_index) * sizeof(void*);
    if (!is_accessible_memory(slot_address, sizeof(void*))) {
        append_log("install failed inaccessible vtable slot vtable=0x%p slot=%u", reinterpret_cast<void*>(vtable), slot_index);
        write_status("slot-inaccessible");
        return false;
    }

    void** slot = reinterpret_cast<void**>(slot_address);
    void* current = nullptr;
    std::memcpy(&current, slot, sizeof(current));
    if (current && !is_executable_memory(reinterpret_cast<uintptr_t>(current))) {
        append_log("install failed non-executable original slot=0x%p current=0x%p", slot, current);
        write_status("original-not-executable");
        return false;
    }

    DWORD old_protect = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_EXECUTE_READWRITE, &old_protect)) {
        append_log("VirtualProtect failed slot=0x%p error=%lu", slot, GetLastError());
        write_status("virtualprotect-failed");
        return false;
    }

    void* previous = InterlockedExchangePointer(slot, reinterpret_cast<void*>(&ProcessEventDetour));
    DWORD ignored = 0;
    VirtualProtect(slot, sizeof(void*), old_protect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));

    if (previous == reinterpret_cast<void*>(&ProcessEventDetour)) {
        previous = reinterpret_cast<void*>(g_original);
    }

    g_vtable = vtable;
    g_slot = slot;
    g_original = reinterpret_cast<ProcessEventFn>(previous);
    g_installed.store(true);

    append_log(
        "installed context=0x%p vtable=0x%p slot=0x%p slot_index=%u original=0x%p detour=0x%p function=0x%p denied_component=0x%p enabled=%d",
        reinterpret_cast<void*>(context),
        reinterpret_cast<void*>(vtable),
        slot,
        slot_index,
        reinterpret_cast<void*>(g_original),
        reinterpret_cast<void*>(&ProcessEventDetour),
        reinterpret_cast<void*>(g_function.load()),
        reinterpret_cast<void*>(g_denied_component.load()),
        g_enabled.load() ? 1 : 0);
    write_status("installed");
    return true;
}

DWORD WINAPI worker_thread(void*) {
    append_log("worker starting");
    for (int attempt = 0; attempt < 40 && !g_installed.load(); ++attempt) {
        if (install_hook()) {
            break;
        }
        Sleep(500);
    }

    while (true) {
        if (load_control()) {
            append_log("control reloaded allowed_context_count=%u", g_allowed_context_count);
            write_status("control-reloaded");
        }
        Sleep(1000);
    }
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        HANDLE thread = CreateThread(nullptr, 0, worker_thread, nullptr, 0, nullptr);
        if (thread) {
            CloseHandle(thread);
        }
    }
    return TRUE;
}
