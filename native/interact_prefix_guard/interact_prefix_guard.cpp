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
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\interact-prefix-guard-control.txt";
const wchar_t* kStatusPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\interact-prefix-guard-status.txt";
const wchar_t* kLogPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\interact-prefix-guard.log";
const wchar_t* kEventPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\interact-prefix-guard-events.tsv";

using NativeFunc = void(__fastcall*)(void* context, void* stack, void* result);

std::atomic<bool> g_enabled{false};
std::atomic<bool> g_block{true};
std::atomic<bool> g_trace{true};
std::atomic<bool> g_deny_unknown{true};
std::atomic<bool> g_allow_empty{true};
std::atomic<bool> g_installed{false};
std::atomic<uintptr_t> g_function{0};
std::atomic<uintptr_t> g_component{0};
std::atomic<uint32_t> g_func_offset{0xD8};
std::atomic<uint32_t> g_locals_offset{0x28};
std::atomic<uint32_t> g_scan_bytes{0x300};
std::atomic<uint64_t> g_hits{0};
std::atomic<uint64_t> g_blocks{0};
std::atomic<uint64_t> g_allows{0};
std::atomic<uint64_t> g_passthrough{0};
std::atomic<uint64_t> g_param_read_failures{0};
std::atomic<uint64_t> g_tag_misses{0};
std::atomic<uint64_t> g_allowed_context_overflow{0};

void** g_func_slot = nullptr;
NativeFunc g_original = nullptr;
SRWLOCK g_policy_lock = SRWLOCK_INIT;
std::vector<std::string> g_allowed_prefixes;
uintptr_t g_allowed_contexts[256]{};
uint32_t g_allowed_context_count = 0;

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
    return parse_numeric_literal(text.c_str() + pos);
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

std::string lower_ascii(const std::string& value) {
    std::string out;
    out.reserve(value.size());
    for (unsigned char ch : value) {
        out.push_back(static_cast<char>(std::tolower(ch)));
    }
    return out;
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

void load_policy_lists(const std::string& text) {
    std::vector<std::string> prefixes;
    uintptr_t contexts[256]{};
    uint32_t context_count = 0;
    uint64_t overflow = 0;

    size_t start = 0;
    while (start <= text.size()) {
        size_t end = text.find_first_of("\r\n", start);
        std::string line = text.substr(start, end == std::string::npos ? std::string::npos : end - start);
        size_t equals = line.find('=');
        if (equals != std::string::npos) {
            std::string key = trim_ascii(line.substr(0, equals));
            std::string value = trim_ascii(line.substr(equals + 1));
            if (key == "allowed_prefix" || key == "allow_prefix") {
                std::string lowered = lower_ascii(value);
                if (!lowered.empty()) {
                    prefixes.push_back(lowered);
                }
            } else if (key == "allowed_context" || key == "allow_context") {
                uintptr_t parsed = parse_numeric_literal(value.c_str());
                if (parsed != 0) {
                    bool duplicate = false;
                    for (uint32_t index = 0; index < context_count; ++index) {
                        if (contexts[index] == parsed) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate) {
                        if (context_count < static_cast<uint32_t>(sizeof(contexts) / sizeof(contexts[0]))) {
                            contexts[context_count++] = parsed;
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

    AcquireSRWLockExclusive(&g_policy_lock);
    g_allowed_prefixes.swap(prefixes);
    std::memset(g_allowed_contexts, 0, sizeof(g_allowed_contexts));
    std::memcpy(g_allowed_contexts, contexts, context_count * sizeof(uintptr_t));
    g_allowed_context_count = context_count;
    ReleaseSRWLockExclusive(&g_policy_lock);
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
    g_trace.store(parse_bool_value(text, "trace", g_trace.load()));
    g_deny_unknown.store(parse_bool_value(text, "deny_unknown", g_deny_unknown.load()));
    g_allow_empty.store(parse_bool_value(text, "allow_empty", g_allow_empty.load()));
    g_function.store(parse_hex_value(text, "function", g_function.load()));
    g_component.store(parse_hex_value(text, "component", g_component.load()));
    g_func_offset.store(static_cast<uint32_t>(parse_hex_value(text, "func_offset", g_func_offset.load())));
    g_locals_offset.store(static_cast<uint32_t>(parse_hex_value(text, "locals_offset", g_locals_offset.load())));
    g_scan_bytes.store(static_cast<uint32_t>(parse_hex_value(text, "scan_bytes", g_scan_bytes.load())));
    load_policy_lists(text);
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
        int32_t readable_len = len;
        if (readable_len > 0 && readable_len <= 512) {
            if (read_utf16_string(data_ptr, readable_len, &text)) {
                push_candidate(candidates, text);
            } else if (read_ansi_string(data_ptr, readable_len, &text)) {
                push_candidate(candidates, text);
            }
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
        if (read_utf16_string(base + offset, 128, &text)) {
            push_candidate(candidates, text);
        } else if (read_ansi_string(base + offset, 128, &text)) {
            push_candidate(candidates, text);
        }
    }
}

bool context_is_allowed(void* context) {
    const uintptr_t context_address = reinterpret_cast<uintptr_t>(context);
    if (context_address == 0) {
        return false;
    }

    bool allowed = false;
    AcquireSRWLockShared(&g_policy_lock);
    for (uint32_t index = 0; index < g_allowed_context_count; ++index) {
        if (g_allowed_contexts[index] == context_address) {
            allowed = true;
            break;
        }
    }
    ReleaseSRWLockShared(&g_policy_lock);
    return allowed;
}

std::string evaluate_prefix(const std::string& tag, bool* out_allowed) {
    if (out_allowed) {
        *out_allowed = true;
    }
    std::string normalized = lower_ascii(trim_ascii(tag));
    if (normalized.empty()) {
        bool allow_empty = g_allow_empty.load();
        if (out_allowed) {
            *out_allowed = allow_empty;
        }
        return allow_empty ? "empty-allowed" : "empty-denied";
    }

    AcquireSRWLockShared(&g_policy_lock);
    for (const std::string& prefix : g_allowed_prefixes) {
        if (!prefix.empty() && normalized.rfind(prefix, 0) == 0) {
            ReleaseSRWLockShared(&g_policy_lock);
            if (out_allowed) {
                *out_allowed = true;
            }
            return "prefix-allowed";
        }
    }
    ReleaseSRWLockShared(&g_policy_lock);

    bool denied = g_deny_unknown.load();
    if (out_allowed) {
        *out_allowed = !denied;
    }
    return denied ? "prefix-denied" : "unknown-allowed";
}

void append_policy_event(
    const char* event_name,
    uint64_t event_id,
    void* context,
    uintptr_t locals,
    uintptr_t component,
    uintptr_t data_struct,
    uintptr_t data_memory,
    const std::string& tag,
    const char* reason) {
    ensure_parent(kEventPath);
    FILE* file = nullptr;
    _wfopen_s(&file, kEventPath, L"ab");
    if (!file) {
        return;
    }

    SYSTEMTIME st{};
    GetSystemTime(&st);
    const char* id_key = std::strcmp(event_name ? event_name : "", "block") == 0 ? "block_id" : "allow_id";
    std::fprintf(
        file,
        "event=%s\t%s=%llu\tpolicy_id=%llu\tutc=%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\tcontext=0x%p\tlocals=0x%p\tcomponent=0x%p\tdata_struct=0x%p\tdata_memory=0x%p\ttag=%s\treason=%s\n",
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
        reinterpret_cast<void*>(data_struct),
        reinterpret_cast<void*>(data_memory),
        tag.c_str(),
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
    std::fprintf(file, "pid=%lu\n", GetCurrentProcessId());
    std::fprintf(file, "installed=%d\n", g_installed.load() ? 1 : 0);
    std::fprintf(file, "enabled=%d\n", g_enabled.load() ? 1 : 0);
    std::fprintf(file, "block=%d\n", g_block.load() ? 1 : 0);
    std::fprintf(file, "trace=%d\n", g_trace.load() ? 1 : 0);
    std::fprintf(file, "deny_unknown=%d\n", g_deny_unknown.load() ? 1 : 0);
    std::fprintf(file, "allow_empty=%d\n", g_allow_empty.load() ? 1 : 0);
    std::fprintf(file, "function=0x%p\n", reinterpret_cast<void*>(g_function.load()));
    std::fprintf(file, "component=0x%p\n", reinterpret_cast<void*>(g_component.load()));
    std::fprintf(file, "func_offset=0x%X\n", g_func_offset.load());
    std::fprintf(file, "locals_offset=0x%X\n", g_locals_offset.load());
    std::fprintf(file, "scan_bytes=0x%X\n", g_scan_bytes.load());
    std::fprintf(file, "func_slot=0x%p\n", reinterpret_cast<void*>(g_func_slot));
    std::fprintf(file, "original=0x%p\n", reinterpret_cast<void*>(g_original));
    std::fprintf(file, "detour=0x%p\n", reinterpret_cast<void*>(&NativeFuncDetour));
    std::fprintf(file, "event_path=C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\interact-prefix-guard-events.tsv\n");
    std::fprintf(file, "hits=%llu\n", static_cast<unsigned long long>(g_hits.load()));
    std::fprintf(file, "blocks=%llu\n", static_cast<unsigned long long>(g_blocks.load()));
    std::fprintf(file, "allows=%llu\n", static_cast<unsigned long long>(g_allows.load()));
    std::fprintf(file, "passthrough=%llu\n", static_cast<unsigned long long>(g_passthrough.load()));
    std::fprintf(file, "param_read_failures=%llu\n", static_cast<unsigned long long>(g_param_read_failures.load()));
    std::fprintf(file, "tag_misses=%llu\n", static_cast<unsigned long long>(g_tag_misses.load()));
    AcquireSRWLockShared(&g_policy_lock);
    std::fprintf(file, "allowed_prefix_count=%zu\n", g_allowed_prefixes.size());
    for (size_t index = 0; index < g_allowed_prefixes.size() && index < 50; ++index) {
        std::fprintf(file, "allowed_prefix_%zu=%s\n", index + 1, g_allowed_prefixes[index].c_str());
    }
    std::fprintf(file, "allowed_context_count=%u\n", g_allowed_context_count);
    for (uint32_t index = 0; index < g_allowed_context_count; ++index) {
        std::fprintf(
            file,
            "allowed_context_%u=0x%p\n",
            index + 1,
            reinterpret_cast<void*>(g_allowed_contexts[index]));
    }
    ReleaseSRWLockShared(&g_policy_lock);
    std::fprintf(file, "allowed_context_overflow=%llu\n", static_cast<unsigned long long>(g_allowed_context_overflow.load()));
    std::fclose(file);
}

bool read_modify_params(void* stack, uintptr_t* out_locals, uintptr_t values[4]) {
    if (!stack || !out_locals || !values) {
        return false;
    }
    uintptr_t locals = 0;
    __try {
        std::memcpy(&locals, static_cast<unsigned char*>(stack) + g_locals_offset.load(), sizeof(uintptr_t));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    if (locals == 0 || !is_accessible_memory(locals, 0x20)) {
        return false;
    }
    __try {
        std::memcpy(values, reinterpret_cast<void*>(locals), sizeof(uintptr_t) * 4);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    *out_locals = locals;
    return true;
}

std::string find_tag_from_params(uintptr_t values[4]) {
    std::vector<std::string> candidates;
    const uint32_t bytes = g_scan_bytes.load();
    scan_fstring_like(values[2], bytes, &candidates);
    scan_fstring_like(values[3], bytes, &candidates);
    scan_direct_strings(values[2], bytes, &candidates);
    scan_direct_strings(values[3], bytes, &candidates);

    for (const std::string& candidate : candidates) {
        std::string normalized = lower_ascii(candidate);
        if (normalized.find(':') != std::string::npos) {
            return candidate;
        }
    }
    if (!candidates.empty()) {
        return candidates[0];
    }
    return "";
}

void __fastcall NativeFuncDetour(void* context, void* stack, void* result) {
    const uint64_t hits = g_hits.fetch_add(1) + 1;

    uintptr_t locals = 0;
    uintptr_t values[4]{};
    const bool params_ok = read_modify_params(stack, &locals, values);
    if (!params_ok) {
        g_param_read_failures.fetch_add(1);
    }

    const uintptr_t component_filter = g_component.load();
    const uintptr_t component = values[1];
    const uintptr_t data_struct = values[2];
    const uintptr_t data_memory = values[3];
    bool component_matches = component_filter == 0 || component == component_filter;
    std::string tag = params_ok && component_matches ? find_tag_from_params(values) : "";
    if (params_ok && component_matches && tag.empty()) {
        g_tag_misses.fetch_add(1);
    }

    if (g_trace.load() && (hits <= 40 || !tag.empty())) {
        append_log(
            "hit context=0x%p stack=0x%p result=0x%p locals=0x%p p0=0x%p component=0x%p data_struct=0x%p data_memory=0x%p component_filter=0x%p component_matches=%d tag=%s enabled=%d block=%d hits=%llu",
            context,
            stack,
            result,
            reinterpret_cast<void*>(locals),
            reinterpret_cast<void*>(values[0]),
            reinterpret_cast<void*>(component),
            reinterpret_cast<void*>(data_struct),
            reinterpret_cast<void*>(data_memory),
            reinterpret_cast<void*>(component_filter),
            component_matches ? 1 : 0,
            tag.c_str(),
            g_enabled.load() ? 1 : 0,
            g_block.load() ? 1 : 0,
            static_cast<unsigned long long>(hits));
    }

    if (g_enabled.load() && params_ok && component_matches && !tag.empty()) {
        if (context_is_allowed(context)) {
            const uint64_t allows = g_allows.fetch_add(1) + 1;
            append_policy_event("allow", allows, context, locals, component, data_struct, data_memory, tag, "ContextAllowlisted");
            write_status("allowed");
            g_passthrough.fetch_add(1);
            if (g_original) {
                g_original(context, stack, result);
            }
            return;
        }

        bool allowed = true;
        std::string decision = evaluate_prefix(tag, &allowed);
        if (!allowed && g_block.load()) {
            const uint64_t blocks = g_blocks.fetch_add(1) + 1;
            append_policy_event("block", blocks, context, locals, component, data_struct, data_memory, tag, decision.c_str());
            append_log(
                "blocked ServerModifyComponent context=0x%p locals=0x%p component=0x%p data_struct=0x%p data_memory=0x%p tag=%s decision=%s blocks=%llu",
                context,
                reinterpret_cast<void*>(locals),
                reinterpret_cast<void*>(component),
                reinterpret_cast<void*>(data_struct),
                reinterpret_cast<void*>(data_memory),
                tag.c_str(),
                decision.c_str(),
                static_cast<unsigned long long>(blocks));
            write_status("blocked");
            return;
        }
        const uint64_t allows = g_allows.fetch_add(1) + 1;
        append_policy_event("allow", allows, context, locals, component, data_struct, data_memory, tag, decision.c_str());
        write_status("allowed");
    }

    g_passthrough.fetch_add(1);
    if (g_original) {
        g_original(context, stack, result);
    }
}

bool install_hook() {
    load_control();

    const uintptr_t function = g_function.load();
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
    g_installed.store(true);

    append_log(
        "installed function=0x%p func_slot=0x%p original=0x%p detour=0x%p component=0x%p enabled=%d block=%d",
        reinterpret_cast<void*>(function),
        slot,
        reinterpret_cast<void*>(g_original),
        reinterpret_cast<void*>(&NativeFuncDetour),
        reinterpret_cast<void*>(g_component.load()),
        g_enabled.load() ? 1 : 0,
        g_block.load() ? 1 : 0);
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
