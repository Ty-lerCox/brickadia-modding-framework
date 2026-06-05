#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <atomic>
#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>

namespace {

const wchar_t* kControlPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\applicator-func-blocker-control.txt";
const wchar_t* kStatusPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\applicator-func-blocker-status.txt";
const wchar_t* kLogPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\applicator-func-blocker.log";
const wchar_t* kEventPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\applicator-func-blocker-events.tsv";

using NativeFunc = void(__fastcall*)(void* context, void* stack, void* result);

struct HookEntry {
    uintptr_t function = 0;
    void** slot = nullptr;
    NativeFunc original = nullptr;
    uint32_t flags = 0;
    uint8_t num_params = 0;
    uint16_t params_size = 0;
};

std::atomic<bool> g_enabled{false};
std::atomic<bool> g_block{true};
std::atomic<bool> g_installed{false};
std::atomic<bool> g_scan_net_native{false};
std::atomic<bool> g_scan_process_memory{false};
std::atomic<bool> g_scan_only{false};
std::atomic<bool> g_multi_mode{false};
std::atomic<uintptr_t> g_function{0};
std::atomic<uintptr_t> g_denied_component{0};
std::atomic<uint32_t> g_func_offset{0xD8};
std::atomic<uint32_t> g_function_flags_offset{0xB0};
std::atomic<uint32_t> g_locals_offset{0x28};
std::atomic<uint32_t> g_node_offset{0x0};
std::atomic<uint32_t> g_required_function_flags{0x440};
std::atomic<uint32_t> g_excluded_function_flags{0x0};
std::atomic<uint32_t> g_max_hooks{512};
std::atomic<uint32_t> g_min_params{1};
std::atomic<uint32_t> g_max_params{8};
std::atomic<uint32_t> g_min_params_size{0x10};
std::atomic<uint32_t> g_max_params_size{0x200};
std::atomic<uintptr_t> g_max_scan_bytes{0x40000000};
std::atomic<uint64_t> g_hits{0};
std::atomic<uint64_t> g_blocks{0};
std::atomic<uint64_t> g_passthrough{0};
std::atomic<uint64_t> g_allowed_itemspawn{0};
std::atomic<uint64_t> g_param_read_failures{0};
std::atomic<uint64_t> g_node_read_failures{0};
std::atomic<uint64_t> g_original_lookup_failures{0};
std::atomic<uint64_t> g_candidate_count{0};
std::atomic<uint64_t> g_hooked_count{0};
std::atomic<uint64_t> g_hook_failures{0};
std::atomic<uint64_t> g_scan_regions{0};
std::atomic<bool> g_scan_truncated{false};

void** g_func_slot = nullptr;
NativeFunc g_original = nullptr;
SRWLOCK g_hooks_lock = SRWLOCK_INIT;
std::vector<HookEntry> g_hooks;
SRWLOCK g_candidate_samples_lock = SRWLOCK_INIT;
std::vector<HookEntry> g_candidate_samples;
SRWLOCK g_allowlist_lock = SRWLOCK_INIT;
uintptr_t g_allowed_contexts[256]{};
uint32_t g_allowed_context_count = 0;
std::atomic<uint64_t> g_allowed_context_overflow{0};

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

void append_policy_event(
    const char* event_name,
    uint64_t event_id,
    void* context,
    uintptr_t locals,
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
    const char* id_key = std::strcmp(event_name ? event_name : "", "allow") == 0 ? "allow_id" : "block_id";
    std::fprintf(
        file,
        "event=%s\t%s=%llu\tpolicy_id=%llu\tutc=%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\tcontext=0x%p\tlocals=0x%p\tcomponent=0x%p\treason=%s\n",
        event_name ? event_name : "",
        id_key,
        static_cast<unsigned long long>(event_id),
        static_cast<unsigned long long>(event_id),
        st.wYear,
        st.wMonth,
        st.wDay,
        st.wHour,
        st.wMinute,
        st.wSecond,
        st.wMilliseconds,
        context,
        reinterpret_cast<void*>(locals),
        reinterpret_cast<void*>(component),
        reason ? reason : "");
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

void load_allowed_contexts(const std::string& text) {
    uintptr_t parsed[256]{};
    uint32_t count = 0;
    uint64_t overflow = 0;

    size_t start = 0;
    while (start <= text.size()) {
        size_t end = text.find_first_of("\r\n", start);
        std::string line = text.substr(start, end == std::string::npos ? std::string::npos : end - start);
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
            if (key_start > 0) {
                key.erase(0, key_start);
            }

            if (key == "allowed_context" || key == "allow_context") {
                const uintptr_t value = parse_numeric_literal(line.c_str() + equals + 1);
                if (value != 0) {
                    bool duplicate = false;
                    for (uint32_t index = 0; index < count; ++index) {
                        if (parsed[index] == value) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate) {
                        if (count < static_cast<uint32_t>(sizeof(parsed) / sizeof(parsed[0]))) {
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

    AcquireSRWLockExclusive(&g_allowlist_lock);
    std::memset(g_allowed_contexts, 0, sizeof(g_allowed_contexts));
    std::memcpy(g_allowed_contexts, parsed, count * sizeof(uintptr_t));
    g_allowed_context_count = count;
    ReleaseSRWLockExclusive(&g_allowlist_lock);
    if (overflow > 0) {
        g_allowed_context_overflow.fetch_add(overflow);
    }
}

void load_control() {
    const std::string text = read_text(kControlPath);
    if (text.empty()) {
        return;
    }

    g_enabled.store(parse_bool_value(text, "enable", g_enabled.load()));
    g_block.store(parse_bool_value(text, "block", g_block.load()));
    g_scan_net_native.store(parse_bool_value(text, "scan_net_native", g_scan_net_native.load()));
    g_scan_process_memory.store(parse_bool_value(text, "scan_process_memory", g_scan_process_memory.load()));
    g_scan_only.store(parse_bool_value(text, "scan_only", g_scan_only.load()));
    g_function.store(parse_hex_value(text, "function", g_function.load()));
    g_denied_component.store(parse_hex_value(text, "denied_component", g_denied_component.load()));
    g_func_offset.store(static_cast<uint32_t>(parse_hex_value(text, "func_offset", g_func_offset.load())));
    g_function_flags_offset.store(static_cast<uint32_t>(parse_hex_value(text, "function_flags_offset", g_function_flags_offset.load())));
    g_locals_offset.store(static_cast<uint32_t>(parse_hex_value(text, "locals_offset", g_locals_offset.load())));
    g_node_offset.store(static_cast<uint32_t>(parse_hex_value(text, "node_offset", g_node_offset.load())));
    g_required_function_flags.store(static_cast<uint32_t>(parse_hex_value(text, "required_function_flags", g_required_function_flags.load())));
    g_excluded_function_flags.store(static_cast<uint32_t>(parse_hex_value(text, "excluded_function_flags", g_excluded_function_flags.load())));
    g_max_hooks.store(static_cast<uint32_t>(parse_hex_value(text, "max_hooks", g_max_hooks.load())));
    g_min_params.store(static_cast<uint32_t>(parse_hex_value(text, "min_params", g_min_params.load())));
    g_max_params.store(static_cast<uint32_t>(parse_hex_value(text, "max_params", g_max_params.load())));
    g_min_params_size.store(static_cast<uint32_t>(parse_hex_value(text, "min_params_size", g_min_params_size.load())));
    g_max_params_size.store(static_cast<uint32_t>(parse_hex_value(text, "max_params_size", g_max_params_size.load())));
    g_max_scan_bytes.store(parse_hex_value(text, "max_scan_bytes", g_max_scan_bytes.load()));
    load_allowed_contexts(text);
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
    std::fprintf(file, "scan_net_native=%d\n", g_scan_net_native.load() ? 1 : 0);
    std::fprintf(file, "scan_process_memory=%d\n", g_scan_process_memory.load() ? 1 : 0);
    std::fprintf(file, "scan_only=%d\n", g_scan_only.load() ? 1 : 0);
    std::fprintf(file, "multi_mode=%d\n", g_multi_mode.load() ? 1 : 0);
    std::fprintf(file, "function=0x%p\n", reinterpret_cast<void*>(g_function.load()));
    std::fprintf(file, "denied_component=0x%p\n", reinterpret_cast<void*>(g_denied_component.load()));
    std::fprintf(file, "func_offset=0x%X\n", g_func_offset.load());
    std::fprintf(file, "function_flags_offset=0x%X\n", g_function_flags_offset.load());
    std::fprintf(file, "locals_offset=0x%X\n", g_locals_offset.load());
    std::fprintf(file, "node_offset=0x%X\n", g_node_offset.load());
    std::fprintf(file, "required_function_flags=0x%X\n", g_required_function_flags.load());
    std::fprintf(file, "excluded_function_flags=0x%X\n", g_excluded_function_flags.load());
    std::fprintf(file, "max_hooks=%u\n", g_max_hooks.load());
    std::fprintf(file, "min_params=%u\n", g_min_params.load());
    std::fprintf(file, "max_params=%u\n", g_max_params.load());
    std::fprintf(file, "min_params_size=0x%X\n", g_min_params_size.load());
    std::fprintf(file, "max_params_size=0x%X\n", g_max_params_size.load());
    std::fprintf(file, "max_scan_bytes=0x%p\n", reinterpret_cast<void*>(g_max_scan_bytes.load()));
    std::fprintf(file, "func_slot=0x%p\n", reinterpret_cast<void*>(g_func_slot));
    std::fprintf(file, "original=0x%p\n", reinterpret_cast<void*>(g_original));
    std::fprintf(file, "detour=0x%p\n", reinterpret_cast<void*>(&NativeFuncDetour));
    std::fprintf(file, "event_path=C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\applicator-func-blocker-events.tsv\n");
    AcquireSRWLockShared(&g_allowlist_lock);
    std::fprintf(file, "allowed_context_count=%u\n", g_allowed_context_count);
    for (uint32_t index = 0; index < g_allowed_context_count; ++index) {
        std::fprintf(
            file,
            "allowed_context_%u=0x%p\n",
            index + 1,
            reinterpret_cast<void*>(g_allowed_contexts[index]));
    }
    ReleaseSRWLockShared(&g_allowlist_lock);
    std::fprintf(file, "hits=%llu\n", static_cast<unsigned long long>(g_hits.load()));
    std::fprintf(file, "blocks=%llu\n", static_cast<unsigned long long>(g_blocks.load()));
    std::fprintf(file, "allowed_itemspawn=%llu\n", static_cast<unsigned long long>(g_allowed_itemspawn.load()));
    std::fprintf(file, "passthrough=%llu\n", static_cast<unsigned long long>(g_passthrough.load()));
    std::fprintf(file, "param_read_failures=%llu\n", static_cast<unsigned long long>(g_param_read_failures.load()));
    std::fprintf(file, "node_read_failures=%llu\n", static_cast<unsigned long long>(g_node_read_failures.load()));
    std::fprintf(file, "original_lookup_failures=%llu\n", static_cast<unsigned long long>(g_original_lookup_failures.load()));
    std::fprintf(file, "candidate_count=%llu\n", static_cast<unsigned long long>(g_candidate_count.load()));
    std::fprintf(file, "hooked_count=%llu\n", static_cast<unsigned long long>(g_hooked_count.load()));
    std::fprintf(file, "hook_failures=%llu\n", static_cast<unsigned long long>(g_hook_failures.load()));
    std::fprintf(file, "scan_regions=%llu\n", static_cast<unsigned long long>(g_scan_regions.load()));
    std::fprintf(file, "scan_truncated=%d\n", g_scan_truncated.load() ? 1 : 0);
    std::fprintf(file, "allowed_context_overflow=%llu\n", static_cast<unsigned long long>(g_allowed_context_overflow.load()));
    AcquireSRWLockShared(&g_hooks_lock);
    const size_t hook_count = g_hooks.size();
    std::fprintf(file, "hook_count=%zu\n", hook_count);
    const size_t detail_count = hook_count < 25 ? hook_count : 25;
    for (size_t index = 0; index < detail_count; ++index) {
        const HookEntry& hook = g_hooks[index];
        std::fprintf(
            file,
            "hook_%zu=function=0x%p slot=0x%p original=0x%p flags=0x%X num_params=%u params_size=0x%X\n",
            index + 1,
            reinterpret_cast<void*>(hook.function),
            hook.slot,
            reinterpret_cast<void*>(hook.original),
            hook.flags,
            static_cast<unsigned>(hook.num_params),
            hook.params_size);
    }
    ReleaseSRWLockShared(&g_hooks_lock);
    AcquireSRWLockShared(&g_candidate_samples_lock);
    const size_t sample_count = g_candidate_samples.size();
    std::fprintf(file, "candidate_sample_count=%zu\n", sample_count);
    const size_t candidate_detail_count = sample_count < 25 ? sample_count : 25;
    for (size_t index = 0; index < candidate_detail_count; ++index) {
        const HookEntry& sample = g_candidate_samples[index];
        std::fprintf(
            file,
            "candidate_sample_%zu=function=0x%p slot=0x%p original=0x%p flags=0x%X num_params=%u params_size=0x%X\n",
            index + 1,
            reinterpret_cast<void*>(sample.function),
            sample.slot,
            reinterpret_cast<void*>(sample.original),
            sample.flags,
            static_cast<unsigned>(sample.num_params),
            sample.params_size);
    }
    ReleaseSRWLockShared(&g_candidate_samples_lock);
    std::fclose(file);
}

bool read_locals_and_component(void* stack, uintptr_t* out_locals, uintptr_t* out_component) {
    if (!stack || !out_locals || !out_component) {
        return false;
    }
    uintptr_t locals = 0;
    uintptr_t component = 0;
    __try {
        std::memcpy(&locals, static_cast<unsigned char*>(stack) + g_locals_offset.load(), sizeof(uintptr_t));
        if (locals == 0) {
            return false;
        }
        std::memcpy(&component, reinterpret_cast<void*>(locals + 8), sizeof(uintptr_t));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    *out_locals = locals;
    *out_component = component;
    return true;
}

bool read_stack_node(void* stack, uintptr_t* out_node) {
    if (!stack || !out_node) {
        return false;
    }
    uintptr_t node = 0;
    __try {
        std::memcpy(&node, static_cast<unsigned char*>(stack) + g_node_offset.load(), sizeof(uintptr_t));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    if (node == 0) {
        return false;
    }
    *out_node = node;
    return true;
}

NativeFunc find_original_for_function(uintptr_t function) {
    if (function == 0) {
        return nullptr;
    }

    NativeFunc original = nullptr;
    AcquireSRWLockShared(&g_hooks_lock);
    auto it = std::lower_bound(
        g_hooks.begin(),
        g_hooks.end(),
        function,
        [](const HookEntry& entry, uintptr_t value) {
            return entry.function < value;
        });
    if (it != g_hooks.end() && it->function == function) {
        original = it->original;
    }
    ReleaseSRWLockShared(&g_hooks_lock);
    return original;
}

void __fastcall NativeFuncDetour(void* context, void* stack, void* result) {
    const uint64_t hits = g_hits.fetch_add(1) + 1;
    const uintptr_t denied_component = g_denied_component.load();
    uintptr_t current_function = g_function.load();
    NativeFunc original = g_original;
    if (g_multi_mode.load()) {
        current_function = 0;
        if (!read_stack_node(stack, &current_function)) {
            g_node_read_failures.fetch_add(1);
        }
        original = find_original_for_function(current_function);
        if (!original) {
            g_original_lookup_failures.fetch_add(1);
        }
    }

    uintptr_t locals = 0;
    uintptr_t component = 0;
    const bool params_ok = read_locals_and_component(stack, &locals, &component);

    if (!params_ok) {
        g_param_read_failures.fetch_add(1);
    }

    if (hits <= 20 || !params_ok || component == denied_component) {
        append_log(
            "hit function=0x%p context=0x%p stack=0x%p result=0x%p locals=0x%p component=0x%p denied=0x%p params_ok=%d original=0x%p enabled=%d block=%d hits=%llu",
            reinterpret_cast<void*>(current_function),
            context,
            stack,
            result,
            reinterpret_cast<void*>(locals),
            reinterpret_cast<void*>(component),
            reinterpret_cast<void*>(denied_component),
            params_ok ? 1 : 0,
            reinterpret_cast<void*>(original),
            g_enabled.load() ? 1 : 0,
            g_block.load() ? 1 : 0,
            static_cast<unsigned long long>(hits));
    }

    if (g_enabled.load() && g_block.load() && denied_component != 0 && params_ok && component == denied_component) {
        if (context_is_allowed(context)) {
            const uint64_t allowed = g_allowed_itemspawn.fetch_add(1) + 1;
            append_policy_event("allow", allowed, context, locals, component, "ContextAllowlisted");
            append_log(
                "allowed ServerAddComponent context=0x%p stack=0x%p locals=0x%p component=0x%p allowed_itemspawn=%llu",
                context,
                stack,
                reinterpret_cast<void*>(locals),
                reinterpret_cast<void*>(component),
                static_cast<unsigned long long>(allowed));
            g_passthrough.fetch_add(1);
            if (original) {
                original(context, stack, result);
            }
            return;
        }

        const uint64_t blocks = g_blocks.fetch_add(1) + 1;
        append_policy_event("block", blocks, context, locals, component, "ItemSpawnDenied");
        append_log(
            "blocked ServerAddComponent context=0x%p stack=0x%p locals=0x%p component=0x%p blocks=%llu",
            context,
            stack,
            reinterpret_cast<void*>(locals),
            reinterpret_cast<void*>(component),
            static_cast<unsigned long long>(blocks));
        write_status("blocked");
        return;
    }

    g_passthrough.fetch_add(1);
    if (original) {
        original(context, stack, result);
    }
}

bool install_single_hook(uintptr_t function) {
    const uint32_t func_offset = g_func_offset.load();
    if (function == 0 || func_offset > 0x400) {
        append_log("install skipped function=0x%p func_offset=0x%X", reinterpret_cast<void*>(function), func_offset);
        write_status("missing-function");
        return false;
    }

    const uintptr_t slot_address = function + func_offset;
    if (!is_accessible_memory(slot_address, sizeof(void*))) {
        append_log(
            "install failed inaccessible func slot function=0x%p slot=0x%p",
            reinterpret_cast<void*>(function),
            reinterpret_cast<void*>(slot_address));
        write_status("slot-inaccessible");
        return false;
    }

    void** slot = reinterpret_cast<void**>(slot_address);
    void* current = nullptr;
    std::memcpy(&current, slot, sizeof(current));
    if (!current || !is_executable_memory(reinterpret_cast<uintptr_t>(current))) {
        append_log("install failed non-executable current slot=0x%p current=0x%p", slot, current);
        write_status("original-not-executable");
        return false;
    }

    DWORD old_protect = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_EXECUTE_READWRITE, &old_protect)) {
        append_log("VirtualProtect failed slot=0x%p error=%lu", slot, GetLastError());
        write_status("virtualprotect-failed");
        return false;
    }

    void* previous = InterlockedExchangePointer(slot, reinterpret_cast<void*>(&NativeFuncDetour));
    DWORD ignored = 0;
    VirtualProtect(slot, sizeof(void*), old_protect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));

    if (previous == reinterpret_cast<void*>(&NativeFuncDetour)) {
        previous = reinterpret_cast<void*>(g_original);
    }

    g_func_slot = slot;
    g_original = reinterpret_cast<NativeFunc>(previous);
    g_multi_mode.store(false);
    g_installed.store(true);

    append_log(
        "installed function=0x%p func_slot=0x%p original=0x%p detour=0x%p denied_component=0x%p func_offset=0x%X locals_offset=0x%X enabled=%d block=%d",
        reinterpret_cast<void*>(function),
        slot,
        reinterpret_cast<void*>(g_original),
        reinterpret_cast<void*>(&NativeFuncDetour),
        reinterpret_cast<void*>(g_denied_component.load()),
        g_func_offset.load(),
        g_locals_offset.load(),
        g_enabled.load() ? 1 : 0,
        g_block.load() ? 1 : 0);
    write_status("installed");
    return true;
}

uintptr_t align_up(uintptr_t value, uintptr_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

bool is_readable_protection(DWORD protect) {
    if ((protect & PAGE_GUARD) || (protect & PAGE_NOACCESS)) {
        return false;
    }
    const DWORD readable =
        PAGE_READONLY |
        PAGE_READWRITE |
        PAGE_WRITECOPY |
        PAGE_EXECUTE_READ |
        PAGE_EXECUTE_READWRITE |
        PAGE_EXECUTE_WRITECOPY;
    return (protect & readable) != 0;
}

bool is_scannable_data_protection(DWORD protect) {
    if ((protect & PAGE_GUARD) || (protect & PAGE_NOACCESS)) {
        return false;
    }
    const DWORD executable =
        PAGE_EXECUTE |
        PAGE_EXECUTE_READ |
        PAGE_EXECUTE_READWRITE |
        PAGE_EXECUTE_WRITECOPY;
    if ((protect & executable) != 0) {
        return false;
    }
    const DWORD data =
        PAGE_READONLY |
        PAGE_READWRITE |
        PAGE_WRITECOPY;
    return (protect & data) != 0;
}

bool read_candidate_function(uintptr_t function, HookEntry* out_entry) {
    if (!out_entry) {
        return false;
    }

    const uint32_t flags_offset = g_function_flags_offset.load();
    const uint32_t func_offset = g_func_offset.load();
    if (flags_offset > 0x400 || func_offset > 0x400) {
        return false;
    }

    const uintptr_t flags_address = function + flags_offset;
    const uintptr_t slot_address = function + func_offset;
    uint32_t flags = 0;
    uint8_t num_params = 0;
    uint16_t params_size = 0;
    void* current = nullptr;

    __try {
        std::memcpy(&flags, reinterpret_cast<void*>(flags_address), sizeof(flags));
        std::memcpy(&num_params, reinterpret_cast<void*>(function + 0xB4), sizeof(num_params));
        std::memcpy(&params_size, reinterpret_cast<void*>(function + 0xB6), sizeof(params_size));
        std::memcpy(&current, reinterpret_cast<void*>(slot_address), sizeof(current));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }

    const uint32_t required = g_required_function_flags.load();
    const uint32_t excluded = g_excluded_function_flags.load();
    if (flags == 0 || (flags & required) != required || (excluded != 0 && (flags & excluded) != 0)) {
        return false;
    }
    if (num_params < g_min_params.load() || num_params > g_max_params.load()) {
        return false;
    }
    if (params_size < g_min_params_size.load() || params_size > g_max_params_size.load()) {
        return false;
    }
    if (!current || current == reinterpret_cast<void*>(&NativeFuncDetour)) {
        return false;
    }
    if (!is_executable_memory(reinterpret_cast<uintptr_t>(current))) {
        return false;
    }

    out_entry->function = function;
    out_entry->slot = reinterpret_cast<void**>(slot_address);
    out_entry->original = reinterpret_cast<NativeFunc>(current);
    out_entry->flags = flags;
    out_entry->num_params = num_params;
    out_entry->params_size = params_size;
    return true;
}

bool hook_candidate(HookEntry* entry) {
    if (!entry || !entry->slot || !entry->original) {
        return false;
    }

    DWORD old_protect = 0;
    if (!VirtualProtect(entry->slot, sizeof(void*), PAGE_EXECUTE_READWRITE, &old_protect)) {
        return false;
    }

    void* previous = InterlockedExchangePointer(entry->slot, reinterpret_cast<void*>(&NativeFuncDetour));
    DWORD ignored = 0;
    VirtualProtect(entry->slot, sizeof(void*), old_protect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), entry->slot, sizeof(void*));

    if (previous == reinterpret_cast<void*>(&NativeFuncDetour)) {
        return false;
    }
    entry->original = reinterpret_cast<NativeFunc>(previous);
    return true;
}

bool install_multi_hooks() {
    const uint32_t max_hooks = g_max_hooks.load();
    if (max_hooks == 0 || max_hooks > 4096) {
        append_log("multi install skipped invalid max_hooks=%u", max_hooks);
        write_status("invalid-max-hooks");
        return false;
    }

    uintptr_t base = 0;
    uintptr_t end = 0;
    if (g_scan_process_memory.load()) {
        SYSTEM_INFO info{};
        GetSystemInfo(&info);
        base = reinterpret_cast<uintptr_t>(info.lpMinimumApplicationAddress);
        end = reinterpret_cast<uintptr_t>(info.lpMaximumApplicationAddress);
    } else {
        HMODULE module = GetModuleHandleW(nullptr);
        if (!module) {
            append_log("multi install failed GetModuleHandleW(nullptr) error=%lu", GetLastError());
            write_status("module-not-found");
            return false;
        }

        base = reinterpret_cast<uintptr_t>(module);
        auto dos = reinterpret_cast<PIMAGE_DOS_HEADER>(base);
        if (dos->e_magic != IMAGE_DOS_SIGNATURE) {
            append_log("multi install failed invalid DOS signature base=0x%p", reinterpret_cast<void*>(base));
            write_status("bad-dos-signature");
            return false;
        }
        auto nt = reinterpret_cast<PIMAGE_NT_HEADERS>(base + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE) {
            append_log("multi install failed invalid NT signature base=0x%p", reinterpret_cast<void*>(base));
            write_status("bad-nt-signature");
            return false;
        }

        end = base + nt->OptionalHeader.SizeOfImage;
    }

    std::vector<HookEntry> hooks;
    hooks.reserve(max_hooks);
    std::vector<HookEntry> candidate_samples;
    candidate_samples.reserve(50);
    uint64_t candidates = 0;
    uint64_t hook_failures = 0;
    uint64_t regions = 0;
    bool truncated = false;
    uintptr_t scanned_bytes = 0;
    const uintptr_t max_scan_bytes = g_max_scan_bytes.load();
    const bool scan_only = g_scan_only.load();

    uintptr_t address = base;
    while (address < end) {
        MEMORY_BASIC_INFORMATION mbi{};
        if (VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0) {
            break;
        }

        const uintptr_t region_start = reinterpret_cast<uintptr_t>(mbi.BaseAddress);
        const uintptr_t region_end = region_start + mbi.RegionSize;
        const uintptr_t scan_start = align_up(region_start < base ? base : region_start, 16);
        const uintptr_t scan_end = region_end > end ? end : region_end;

        if (mbi.State == MEM_COMMIT && is_scannable_data_protection(mbi.Protect) && scan_start < scan_end) {
            ++regions;
            const uintptr_t region_bytes = scan_end - scan_start;
            if (max_scan_bytes != 0 && scanned_bytes + region_bytes > max_scan_bytes) {
                truncated = true;
                break;
            }
            scanned_bytes += region_bytes;
            for (uintptr_t cursor = scan_start; cursor + g_func_offset.load() + sizeof(void*) <= scan_end; cursor += 16) {
                HookEntry entry{};
                if (!read_candidate_function(cursor, &entry)) {
                    continue;
                }
                ++candidates;
                if (candidate_samples.size() < 50) {
                    candidate_samples.push_back(entry);
                }
                if (hooks.size() >= max_hooks) {
                    truncated = true;
                    break;
                }
                if (scan_only) {
                    continue;
                }
                if (hook_candidate(&entry)) {
                    hooks.push_back(entry);
                    if (hooks.size() <= 30) {
                        append_log(
                            "multi hooked function=0x%p slot=0x%p original=0x%p flags=0x%X num_params=%u params_size=0x%X",
                            reinterpret_cast<void*>(entry.function),
                            entry.slot,
                            reinterpret_cast<void*>(entry.original),
                            entry.flags,
                            static_cast<unsigned>(entry.num_params),
                            entry.params_size);
                    }
                } else {
                    ++hook_failures;
                }
            }
        }

        if (truncated) {
            break;
        }
        address = region_end;
    }

    std::sort(hooks.begin(), hooks.end(), [](const HookEntry& left, const HookEntry& right) {
        return left.function < right.function;
    });

    AcquireSRWLockExclusive(&g_hooks_lock);
    g_hooks.swap(hooks);
    ReleaseSRWLockExclusive(&g_hooks_lock);
    AcquireSRWLockExclusive(&g_candidate_samples_lock);
    g_candidate_samples.swap(candidate_samples);
    ReleaseSRWLockExclusive(&g_candidate_samples_lock);

    g_candidate_count.store(candidates);
    g_hooked_count.store(static_cast<uint64_t>(g_hooks.size()));
    g_hook_failures.store(hook_failures);
    g_scan_regions.store(regions);
    g_scan_truncated.store(truncated);

    if (scan_only) {
        append_log(
            "multi scan-only completed scope=%s base=0x%p end=0x%p required_flags=0x%X flags_offset=0x%X func_offset=0x%X candidates=%llu regions=%llu scanned_bytes=0x%p truncated=%d",
            g_scan_process_memory.load() ? "process" : "module",
            reinterpret_cast<void*>(base),
            reinterpret_cast<void*>(end),
            g_required_function_flags.load(),
            g_function_flags_offset.load(),
            g_func_offset.load(),
            static_cast<unsigned long long>(candidates),
            static_cast<unsigned long long>(regions),
            reinterpret_cast<void*>(scanned_bytes),
            truncated ? 1 : 0);
        write_status(candidates > 0 ? "scan-only-candidates" : "scan-only-no-candidates");
        return true;
    }

    if (g_hooks.empty()) {
        append_log(
            "multi install found no hooks scope=%s base=0x%p end=0x%p required_flags=0x%X flags_offset=0x%X func_offset=0x%X candidates=%llu failures=%llu regions=%llu scanned_bytes=0x%p",
            g_scan_process_memory.load() ? "process" : "module",
            reinterpret_cast<void*>(base),
            reinterpret_cast<void*>(end),
            g_required_function_flags.load(),
            g_function_flags_offset.load(),
            g_func_offset.load(),
            static_cast<unsigned long long>(candidates),
            static_cast<unsigned long long>(hook_failures),
            static_cast<unsigned long long>(regions),
            reinterpret_cast<void*>(scanned_bytes));
        write_status("no-multi-hooks");
        return false;
    }

    g_func_slot = g_hooks[0].slot;
    g_original = g_hooks[0].original;
    g_multi_mode.store(true);
    g_installed.store(true);
    append_log(
        "multi installed scope=%s hooks=%zu candidates=%llu failures=%llu regions=%llu scanned_bytes=0x%p truncated=%d denied_component=0x%p required_flags=0x%X flags_offset=0x%X func_offset=0x%X locals_offset=0x%X node_offset=0x%X enabled=%d block=%d",
        g_scan_process_memory.load() ? "process" : "module",
        g_hooks.size(),
        static_cast<unsigned long long>(candidates),
        static_cast<unsigned long long>(hook_failures),
        static_cast<unsigned long long>(regions),
        reinterpret_cast<void*>(scanned_bytes),
        truncated ? 1 : 0,
        reinterpret_cast<void*>(g_denied_component.load()),
        g_required_function_flags.load(),
        g_function_flags_offset.load(),
        g_func_offset.load(),
        g_locals_offset.load(),
        g_node_offset.load(),
        g_enabled.load() ? 1 : 0,
        g_block.load() ? 1 : 0);
    write_status("multi-installed");
    return true;
}

bool install_hook() {
    load_control();

    const uintptr_t function = g_function.load();
    if (function != 0) {
        return install_single_hook(function);
    }
    if (g_scan_net_native.load()) {
        return install_multi_hooks();
    }

    append_log("install skipped missing function and scan_net_native=0");
    write_status("missing-function");
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
        load_control();
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
