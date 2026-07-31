#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <timeapi.h>

#include <Mod/CppUserModBase.hpp>
#include <UEngine.hpp>
#include <Unreal/Hooks/Hooks.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>

using namespace RC;

namespace
{
    constexpr uint64_t kSlow16ThresholdUs = 16667;
    constexpr uint64_t kSlow33ThresholdUs = 33333;
    constexpr uint64_t kSlow50ThresholdUs = 50000;
    constexpr uint64_t kSlow100ThresholdUs = 100000;

    std::string json_escape(std::string_view value)
    {
        std::string out;
        out.reserve(value.size() + 8);
        for (char ch : value)
        {
            switch (ch)
            {
            case '\\':
                out += "\\\\";
                break;
            case '"':
                out += "\\\"";
                break;
            case '\r':
                out += "\\r";
                break;
            case '\n':
                out += "\\n";
                break;
            case '\t':
                out += "\\t";
                break;
            default:
                out += static_cast<unsigned char>(ch) < 0x20 ? '?' : ch;
                break;
            }
        }
        return out;
    }

    uint64_t unix_time_ms()
    {
        const auto now = std::chrono::system_clock::now().time_since_epoch();
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(now).count());
    }

    uint64_t delta_to_microseconds(float delta_seconds)
    {
        if (!std::isfinite(delta_seconds) || delta_seconds < 0.0f)
        {
            return 0;
        }
        return static_cast<uint64_t>(std::llround(static_cast<double>(delta_seconds) * 1000000.0));
    }

    double us_to_ms(uint64_t value)
    {
        return static_cast<double>(value) / 1000.0;
    }

    void atomic_max(std::atomic<uint64_t>& target, uint64_t value)
    {
        uint64_t current = target.load(std::memory_order_relaxed);
        while (value > current &&
               !target.compare_exchange_weak(current, value, std::memory_order_relaxed, std::memory_order_relaxed))
        {
        }
    }

    std::filesystem::path current_module_path()
    {
        HMODULE module = nullptr;
        if (!GetModuleHandleExW(
                GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                reinterpret_cast<LPCWSTR>(&current_module_path),
                &module))
        {
            return {};
        }

        std::wstring buffer;
        buffer.resize(32768);
        const DWORD size = GetModuleFileNameW(module, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (size == 0 || size >= buffer.size())
        {
            return {};
        }
        buffer.resize(size);
        return std::filesystem::path(buffer);
    }

    std::wstring getenv_wide(const wchar_t* name)
    {
        wchar_t* raw = nullptr;
        size_t length = 0;
        if (_wdupenv_s(&raw, &length, name) != 0 || !raw)
        {
            return {};
        }
        std::wstring value(raw);
        std::free(raw);
        return value;
    }

    std::string getenv_narrow(const char* name)
    {
        char* raw = nullptr;
        size_t length = 0;
        if (_dupenv_s(&raw, &length, name) != 0 || !raw)
        {
            return {};
        }
        std::string value(raw);
        std::free(raw);
        return value;
    }

    bool env_flag_enabled(const char* name, bool default_value)
    {
        std::string text = getenv_narrow(name);
        if (text.empty())
        {
            return default_value;
        }
        for (char& ch : text)
        {
            if (ch >= 'A' && ch <= 'Z')
            {
                ch = static_cast<char>(ch - 'A' + 'a');
            }
        }
        return text != "0" && text != "false" && text != "off" && text != "no";
    }

    struct TargetFpsConfig
    {
        uint32_t value = 60;
        bool valid = true;
    };

    TargetFpsConfig target_fps_config()
    {
        const std::string text = getenv_narrow("BMF_FRAME_PACING_TARGET_FPS");
        if (text.empty())
        {
            return {};
        }

        errno = 0;
        char* end = nullptr;
        const long parsed = std::strtol(text.c_str(), &end, 10);
        while (end && (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n'))
        {
            ++end;
        }
        if (errno == 0 && end && *end == '\0' && (parsed == 60 || parsed == 120))
        {
            return {static_cast<uint32_t>(parsed), true};
        }
        return {60, false};
    }

    std::filesystem::path default_output_path()
    {
        const std::wstring configured = getenv_wide(L"BMF_FRAME_TELEMETRY_PATH");
        if (!configured.empty())
        {
            return std::filesystem::path(configured);
        }

        const auto dll_path = current_module_path();
        if (dll_path.empty())
        {
            return std::filesystem::path(L"BMF-frame-telemetry.json");
        }

        const auto mod_dir = dll_path.parent_path().parent_path();
        const auto mods_dir = mod_dir.parent_path();
        return mods_dir / L"BMF" / L"runtime" / L"frame-telemetry.json";
    }

    bool env_enabled()
    {
        return env_flag_enabled("BMF_FRAME_TELEMETRY_ENABLED", true);
    }

    bool is_accessible_memory(uintptr_t address, size_t bytes)
    {
        MEMORY_BASIC_INFORMATION mbi{};
        if (address == 0 || bytes == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0)
        {
            return false;
        }
        if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS))
        {
            return false;
        }
        const uintptr_t region_start = reinterpret_cast<uintptr_t>(mbi.BaseAddress);
        if (region_start > UINTPTR_MAX - mbi.RegionSize)
        {
            return false;
        }
        const uintptr_t region_end = region_start + mbi.RegionSize;
        return address >= region_start && address + bytes >= address && address + bytes <= region_end;
    }

    bool is_executable_memory(uintptr_t address)
    {
        MEMORY_BASIC_INFORMATION mbi{};
        if (address == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0)
        {
            return false;
        }
        if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS))
        {
            return false;
        }
        const DWORD execute_flags =
            PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
        return (mbi.Protect & execute_flags) != 0;
    }

    bool is_main_module_executable(void* address)
    {
        MEMORY_BASIC_INFORMATION mbi{};
        const auto module = GetModuleHandleW(nullptr);
        return address && module &&
               VirtualQuery(address, &mbi, sizeof(mbi)) != 0 &&
               mbi.AllocationBase == module &&
               is_executable_memory(reinterpret_cast<uintptr_t>(address));
    }

    void* get_uobject_vtable_entry(Unreal::UObject* object, std::size_t vtable_offset)
    {
        if (!object ||
            vtable_offset % sizeof(void*) != 0 ||
            vtable_offset > 0x2000 ||
            !is_accessible_memory(reinterpret_cast<uintptr_t>(object), sizeof(void*)))
        {
            return nullptr;
        }

        auto** vtable = *reinterpret_cast<void***>(object);
        if (!vtable ||
            !is_accessible_memory(reinterpret_cast<uintptr_t>(vtable) + vtable_offset, sizeof(void*)))
        {
            return nullptr;
        }

        void* entry = vtable[vtable_offset / sizeof(void*)];
        return is_executable_memory(reinterpret_cast<uintptr_t>(entry)) ? entry : nullptr;
    }

    bool get_uobject_vtable_entry_guarded(Unreal::UObject* object,
                                          std::size_t vtable_offset,
                                          void*& entry,
                                          unsigned long& exception_code)
    {
        entry = nullptr;
        exception_code = 0;
        __try
        {
            entry = get_uobject_vtable_entry(object, vtable_offset);
            return true;
        }
        __except ((exception_code = GetExceptionInformation()->ExceptionRecord->ExceptionCode), EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    bool matches_masked_bytes(void* entry,
                              const uint8_t* expected,
                              const uint8_t* mask,
                              std::size_t size)
    {
        if (!entry || !expected || !mask || size == 0 ||
            !is_accessible_memory(reinterpret_cast<uintptr_t>(entry), size))
        {
            return false;
        }

        const auto* bytes = static_cast<const uint8_t*>(entry);
        for (std::size_t index = 0; index < size; ++index)
        {
            if ((bytes[index] & mask[index]) != (expected[index] & mask[index]))
            {
                return false;
            }
        }
        return true;
    }

    bool matches_current_get_max_fps(void* entry)
    {
        // CL24084343 / Release-EA3-CL-14860. RIP-relative displacements and
        // short branch distances are masked; the remaining instructions are
        // the validated t.MaxFPS getter prologue.
        static constexpr uint8_t expected[] = {
            0x56, 0x57, 0x48, 0x83, 0xEC, 0x28, 0x48, 0x8B, 0x35, 0x00, 0x00, 0x00, 0x00,
            0x48, 0x85, 0xF6, 0x74, 0x00, 0x8B, 0x05, 0x00, 0x00, 0x00, 0x00, 0x65, 0x48,
            0x8B, 0x0C, 0x25, 0x58, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x04, 0xC1, 0x8B, 0x80,
            0x70, 0x0B, 0x00, 0x00, 0x31, 0xC9, 0x3D, 0x02, 0x00, 0x00, 0x40,
        };
        static constexpr uint8_t mask[] = {
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
            0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        };
        static_assert(sizeof(expected) == sizeof(mask));
        return matches_masked_bytes(entry, expected, mask, sizeof(expected));
    }

    bool matches_current_set_max_fps(void* entry)
    {
        // Validated t.MaxFPS setter prologue. It consumes the requested float
        // from XMM1 before entering the console-variable Set path.
        static constexpr uint8_t expected[] = {
            0x56, 0x57, 0x53, 0x48, 0x81, 0xEC, 0x80, 0x00, 0x00, 0x00,
            0xC5, 0xF8, 0x29, 0x74, 0x24, 0x70, 0xC5, 0xF8, 0x28, 0xF1,
        };
        static constexpr uint8_t mask[] = {
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        };
        static_assert(sizeof(expected) == sizeof(mask));
        return matches_masked_bytes(entry, expected, mask, sizeof(expected));
    }

    bool matches_current_get_max_tick_rate(void* entry)
    {
        // Validated UGameEngine::GetMaxTickRate override prologue for the
        // current server build. This guards the readback call independently
        // from the adjacent t.MaxFPS getter/setter checks.
        static constexpr uint8_t expected[] = {
            0x56, 0x57, 0x53, 0x48, 0x83, 0xEC, 0x40, 0xC5, 0xF8, 0x29,
            0x7C, 0x24, 0x30, 0xC5, 0xF8, 0x29, 0x74, 0x24, 0x20,
        };
        static constexpr uint8_t mask[] = {
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        };
        static_assert(sizeof(expected) == sizeof(mask));
        return matches_masked_bytes(entry, expected, mask, sizeof(expected));
    }

    using SetMaxFpsFunction = void (*)(Unreal::UEngine*, float);
    using GetMaxFpsFunction = float (*)(const Unreal::UEngine*);
    using GetMaxTickRateFunction = float (*)(const Unreal::UEngine*, float, bool);

    bool set_max_fps_guarded(Unreal::UEngine* engine,
                             void* entry,
                             float target_fps,
                             unsigned long& exception_code)
    {
        exception_code = 0;
        __try
        {
            reinterpret_cast<SetMaxFpsFunction>(entry)(engine, target_fps);
            return true;
        }
        __except ((exception_code = GetExceptionInformation()->ExceptionRecord->ExceptionCode), EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    bool get_max_fps_guarded(const Unreal::UEngine* engine,
                             void* entry,
                             float& value,
                             unsigned long& exception_code)
    {
        value = 0.0f;
        exception_code = 0;
        __try
        {
            value = reinterpret_cast<GetMaxFpsFunction>(entry)(engine);
            return true;
        }
        __except ((exception_code = GetExceptionInformation()->ExceptionRecord->ExceptionCode), EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    bool get_max_tick_rate_guarded(const Unreal::UEngine* engine,
                                   void* entry,
                                   float& value,
                                   unsigned long& exception_code)
    {
        value = 0.0f;
        exception_code = 0;
        __try
        {
            value = reinterpret_cast<GetMaxTickRateFunction>(entry)(engine, 0.0f, false);
            return true;
        }
        __except ((exception_code = GetExceptionInformation()->ExceptionRecord->ExceptionCode), EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    enum class TargetOverrideResult : uint32_t
    {
        NotAttempted = 0,
        Applied = 1,
        EngineUnavailable = 2,
        LayoutUnavailable = 3,
        VirtualEntryUnavailable = 4,
        SetException = 5,
        ReadbackException = 6,
        VerificationFailed = 7,
        LayoutCalibrationFailed = 8,
        SignatureMismatch = 9,
        GetterValidationFailed = 10,
    };

    const char* target_override_result_name(TargetOverrideResult result)
    {
        switch (result)
        {
        case TargetOverrideResult::Applied:
            return "applied";
        case TargetOverrideResult::EngineUnavailable:
            return "engine_unavailable";
        case TargetOverrideResult::LayoutUnavailable:
            return "layout_unavailable";
        case TargetOverrideResult::VirtualEntryUnavailable:
            return "virtual_entry_unavailable";
        case TargetOverrideResult::SetException:
            return "set_exception";
        case TargetOverrideResult::ReadbackException:
            return "readback_exception";
        case TargetOverrideResult::VerificationFailed:
            return "verification_failed";
        case TargetOverrideResult::LayoutCalibrationFailed:
            return "layout_calibration_failed";
        case TargetOverrideResult::SignatureMismatch:
            return "signature_mismatch";
        case TargetOverrideResult::GetterValidationFailed:
            return "getter_validation_failed";
        case TargetOverrideResult::NotAttempted:
        default:
            return "not_attempted";
        }
    }

    class FramePacingPolicy
    {
      public:
        FramePacingPolicy()
            : enabled_(env_flag_enabled("BMF_FRAME_PACING_ENABLED", true)), target_config_(target_fps_config())
        {
        }

        ~FramePacingPolicy()
        {
            stop();
        }

        void start()
        {
            bool expected = false;
            if (!started_.compare_exchange_strong(expected, true))
            {
                return;
            }

            if (!enabled_)
            {
                std::printf("[BMFFrameTelemetry] frame pacing disabled by BMF_FRAME_PACING_ENABLED\n");
                return;
            }

            power_policy_attempted_.store(true, std::memory_order_relaxed);
            PROCESS_POWER_THROTTLING_STATE state{};
            state.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
            state.ControlMask = PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION;
            state.StateMask = 0;
            SetLastError(ERROR_SUCCESS);
            const BOOL policy_applied = SetProcessInformation(
                GetCurrentProcess(), ProcessPowerThrottling, &state, sizeof(state));
            power_policy_applied_.store(policy_applied != FALSE, std::memory_order_relaxed);
            power_policy_error_.store(policy_applied ? ERROR_SUCCESS : GetLastError(), std::memory_order_relaxed);

            const MMRESULT timer_result = timeBeginPeriod(kTimerResolutionMs);
            timer_begin_result_.store(static_cast<uint32_t>(timer_result), std::memory_order_relaxed);
            const bool timer_succeeded = timer_result == TIMERR_NOERROR;
            timer_begin_succeeded_.store(timer_succeeded, std::memory_order_relaxed);
            timer_active_.store(timer_succeeded, std::memory_order_relaxed);

            if (!target_config_.valid)
            {
                std::printf(
                    "[BMFFrameTelemetry] invalid BMF_FRAME_PACING_TARGET_FPS; falling back to 60\n");
            }
            std::printf(
                "[BMFFrameTelemetry] frame pacing startup target_fps=%u power_policy_applied=%d "
                "power_policy_error=%lu timer_resolution_ms=%u timer_result=%u\n",
                target_config_.value,
                policy_applied ? 1 : 0,
                static_cast<unsigned long>(power_policy_error_.load(std::memory_order_relaxed)),
                kTimerResolutionMs,
                static_cast<unsigned int>(timer_result));
        }

        void stop()
        {
            if (timer_active_.exchange(false, std::memory_order_relaxed))
            {
                timeEndPeriod(kTimerResolutionMs);
            }
        }

        bool should_apply_target() const
        {
            return enabled_;
        }

        void apply_target_once(Unreal::UEngine* engine)
        {
            if (target_attempted_.exchange(true, std::memory_order_relaxed))
            {
                return;
            }
            if (!engine)
            {
                target_result_.store(TargetOverrideResult::EngineUnavailable, std::memory_order_relaxed);
                return;
            }

            const auto named_engine_tick_it = Unreal::UEngine::VTableLayoutMap.find(STR("Tick"));
            const auto named_set_it = Unreal::UEngine::VTableLayoutMap.find(STR("SetMaxFPS"));
            const auto named_get_it = Unreal::UEngine::VTableLayoutMap.find(STR("GetMaxFPS"));
            const auto named_tick_rate_it = Unreal::UEngine::VTableLayoutMap.find(STR("GetMaxTickRate"));
            if (named_engine_tick_it == Unreal::UEngine::VTableLayoutMap.end() ||
                named_set_it == Unreal::UEngine::VTableLayoutMap.end() ||
                named_get_it == Unreal::UEngine::VTableLayoutMap.end() ||
                named_tick_rate_it == Unreal::UEngine::VTableLayoutMap.end())
            {
                target_result_.store(TargetOverrideResult::LayoutUnavailable, std::memory_order_relaxed);
                std::printf("[BMFFrameTelemetry] frame target unavailable: UE4SS named engine layout is incomplete\n");
                return;
            }

            // Brickadia can update ahead of the installed UE4SS compatibility
            // bundle. Calibrate its uniformly shifted named layout against the
            // independently scanned Tick function that UE4SS is already using
            // for this callback. Never call a candidate setter unless exactly
            // one vtable slot matches that live Tick address.
            void* scanned_engine_tick = Unreal::UEngine::TickInternal.get_function_address();
            if (!is_main_module_executable(scanned_engine_tick))
            {
                target_result_.store(TargetOverrideResult::LayoutCalibrationFailed, std::memory_order_relaxed);
                std::printf("[BMFFrameTelemetry] frame target unavailable: scanned engine Tick is not ready\n");
                return;
            }

            constexpr std::size_t kCalibrationRadiusBytes = 0x80;
            const std::size_t named_engine_tick = named_engine_tick_it->second;
            const std::size_t search_start =
                named_engine_tick > kCalibrationRadiusBytes ? named_engine_tick - kCalibrationRadiusBytes : 0;
            const std::size_t search_end =
                std::min<std::size_t>(0x2000, named_engine_tick + kCalibrationRadiusBytes);
            std::size_t calibrated_engine_tick = 0;
            uint32_t calibration_matches = 0;
            unsigned long exception_code = 0;
            for (std::size_t offset = search_start; offset <= search_end; offset += sizeof(void*))
            {
                void* candidate = nullptr;
                unsigned long candidate_exception = 0;
                if (!get_uobject_vtable_entry_guarded(engine, offset, candidate, candidate_exception))
                {
                    exception_code = candidate_exception;
                    continue;
                }
                if (candidate == scanned_engine_tick)
                {
                    calibrated_engine_tick = offset;
                    ++calibration_matches;
                }
            }

            if (calibration_matches != 1)
            {
                target_exception_code_.store(exception_code, std::memory_order_relaxed);
                target_result_.store(TargetOverrideResult::LayoutCalibrationFailed, std::memory_order_relaxed);
                std::printf(
                    "[BMFFrameTelemetry] frame target unavailable: engine layout calibration matches=%u\n",
                    calibration_matches);
                return;
            }

            const std::ptrdiff_t layout_adjustment =
                static_cast<std::ptrdiff_t>(calibrated_engine_tick) -
                static_cast<std::ptrdiff_t>(named_engine_tick);
            const auto adjusted_offset = [layout_adjustment](uint32_t named_offset, std::size_t& value) {
                const auto adjusted = static_cast<std::ptrdiff_t>(named_offset) + layout_adjustment;
                if (adjusted < 0 || adjusted > 0x2000 || adjusted % static_cast<std::ptrdiff_t>(sizeof(void*)) != 0)
                {
                    return false;
                }
                value = static_cast<std::size_t>(adjusted);
                return true;
            };

            std::size_t set_offset = 0;
            std::size_t get_offset = 0;
            std::size_t tick_rate_offset = 0;
            if (!adjusted_offset(named_set_it->second, set_offset) ||
                !adjusted_offset(named_get_it->second, get_offset) ||
                !adjusted_offset(named_tick_rate_it->second, tick_rate_offset) ||
                get_offset + sizeof(void*) != set_offset ||
                tick_rate_offset + sizeof(void*) != get_offset)
            {
                target_result_.store(TargetOverrideResult::LayoutCalibrationFailed, std::memory_order_relaxed);
                std::printf("[BMFFrameTelemetry] frame target unavailable: calibrated engine layout is not contiguous\n");
                return;
            }

            void* set_entry = nullptr;
            void* get_entry = nullptr;
            void* tick_entry = nullptr;
            if (!get_uobject_vtable_entry_guarded(engine, set_offset, set_entry, exception_code) ||
                !set_entry ||
                !get_uobject_vtable_entry_guarded(engine, get_offset, get_entry, exception_code) ||
                !get_entry ||
                !get_uobject_vtable_entry_guarded(engine, tick_rate_offset, tick_entry, exception_code) ||
                !tick_entry)
            {
                target_exception_code_.store(exception_code, std::memory_order_relaxed);
                target_result_.store(TargetOverrideResult::VirtualEntryUnavailable, std::memory_order_relaxed);
                std::printf(
                    "[BMFFrameTelemetry] frame target unavailable: guarded virtual resolution failed exception=0x%08lx\n",
                    exception_code);
                return;
            }

            if (set_entry == get_entry || set_entry == tick_entry || get_entry == tick_entry ||
                !is_main_module_executable(set_entry) ||
                !is_main_module_executable(get_entry) ||
                !is_main_module_executable(tick_entry) ||
                !matches_current_get_max_fps(get_entry) ||
                !matches_current_set_max_fps(set_entry) ||
                !matches_current_get_max_tick_rate(tick_entry))
            {
                target_result_.store(TargetOverrideResult::SignatureMismatch, std::memory_order_relaxed);
                std::printf("[BMFFrameTelemetry] frame target unavailable: calibrated function validation failed\n");
                return;
            }

            layout_calibrated_.store(true, std::memory_order_relaxed);
            layout_adjustment_bytes_.store(static_cast<int32_t>(layout_adjustment), std::memory_order_relaxed);
            entry_signatures_valid_.store(true, std::memory_order_relaxed);

            float previous_max_fps = 0.0f;
            float previous_max_tick_rate = 0.0f;
            if (!get_max_fps_guarded(engine, get_entry, previous_max_fps, exception_code) ||
                !get_max_tick_rate_guarded(engine, tick_entry, previous_max_tick_rate, exception_code))
            {
                target_exception_code_.store(exception_code, std::memory_order_relaxed);
                target_result_.store(TargetOverrideResult::ReadbackException, std::memory_order_relaxed);
                return;
            }
            if (!std::isfinite(previous_max_fps) || previous_max_fps < 0.0f || previous_max_fps > 1000.0f ||
                !std::isfinite(previous_max_tick_rate) || previous_max_tick_rate < 0.0f ||
                previous_max_tick_rate > 1000.0f)
            {
                target_result_.store(TargetOverrideResult::GetterValidationFailed, std::memory_order_relaxed);
                std::printf(
                    "[BMFFrameTelemetry] frame target unavailable: getter validation max_fps=%.3f max_tick_rate=%.3f\n",
                    previous_max_fps,
                    previous_max_tick_rate);
                return;
            }
            previous_max_fps_milli_.store(fps_to_milli(previous_max_fps), std::memory_order_relaxed);
            previous_max_tick_rate_milli_.store(fps_to_milli(previous_max_tick_rate), std::memory_order_relaxed);

            if (!set_max_fps_guarded(engine, set_entry, static_cast<float>(target_config_.value), exception_code))
            {
                target_exception_code_.store(exception_code, std::memory_order_relaxed);
                target_result_.store(TargetOverrideResult::SetException, std::memory_order_relaxed);
                return;
            }

            float observed_max_fps = 0.0f;
            float observed_max_tick_rate = 0.0f;
            if (!get_max_fps_guarded(engine, get_entry, observed_max_fps, exception_code) ||
                !get_max_tick_rate_guarded(engine, tick_entry, observed_max_tick_rate, exception_code))
            {
                target_exception_code_.store(exception_code, std::memory_order_relaxed);
                target_result_.store(TargetOverrideResult::ReadbackException, std::memory_order_relaxed);
                return;
            }

            observed_max_fps_milli_.store(fps_to_milli(observed_max_fps), std::memory_order_relaxed);
            observed_max_tick_rate_milli_.store(fps_to_milli(observed_max_tick_rate), std::memory_order_relaxed);
            const float target = static_cast<float>(target_config_.value);
            const bool applied = std::isfinite(observed_max_fps) &&
                                 std::isfinite(observed_max_tick_rate) &&
                                 std::fabs(observed_max_fps - target) < 0.5f &&
                                 std::fabs(observed_max_tick_rate - target) < 0.5f;
            target_applied_.store(applied, std::memory_order_relaxed);
            target_result_.store(
                applied ? TargetOverrideResult::Applied : TargetOverrideResult::VerificationFailed,
                std::memory_order_relaxed);
            std::printf(
                "[BMFFrameTelemetry] frame target target_fps=%u applied=%d layout_adjustment=%d "
                "previous_max_fps=%.3f previous_max_tick_rate=%.3f observed_max_fps=%.3f "
                "observed_max_tick_rate=%.3f\n",
                target_config_.value,
                applied ? 1 : 0,
                static_cast<int>(layout_adjustment),
                previous_max_fps,
                previous_max_tick_rate,
                observed_max_fps,
                observed_max_tick_rate);
        }

        std::string status_json() const
        {
            const auto result = target_result_.load(std::memory_order_relaxed);
            std::ostringstream out;
            out.setf(std::ios::fixed);
            out.precision(3);
            out << "{"
                << "\"enabled\":" << (enabled_ ? "true" : "false") << ","
                << "\"config_valid\":" << (target_config_.valid ? "true" : "false") << ","
                << "\"target_fps\":" << target_config_.value << ","
                << "\"target_override_attempted\":"
                << (target_attempted_.load(std::memory_order_relaxed) ? "true" : "false") << ","
                << "\"target_override_applied\":"
                << (target_applied_.load(std::memory_order_relaxed) ? "true" : "false") << ","
                << "\"target_override_result\":\"" << target_override_result_name(result) << "\","
                << "\"target_exception_code\":"
                << target_exception_code_.load(std::memory_order_relaxed) << ","
                << "\"layout_calibrated\":"
                << (layout_calibrated_.load(std::memory_order_relaxed) ? "true" : "false") << ","
                << "\"layout_adjustment_bytes\":"
                << layout_adjustment_bytes_.load(std::memory_order_relaxed) << ","
                << "\"entry_signatures_valid\":"
                << (entry_signatures_valid_.load(std::memory_order_relaxed) ? "true" : "false") << ","
                << "\"previous_max_fps\":";
            append_optional_fps(out, previous_max_fps_milli_.load(std::memory_order_relaxed));
            out << ",\"previous_max_tick_rate\":";
            append_optional_fps(out, previous_max_tick_rate_milli_.load(std::memory_order_relaxed));
            out << ",\"observed_max_fps\":";
            append_optional_fps(out, observed_max_fps_milli_.load(std::memory_order_relaxed));
            out << ",\"observed_max_tick_rate\":";
            append_optional_fps(out, observed_max_tick_rate_milli_.load(std::memory_order_relaxed));
            out << ","
                << "\"timer_policy_attempted\":"
                << (power_policy_attempted_.load(std::memory_order_relaxed) ? "true" : "false") << ","
                << "\"timer_policy_applied\":"
                << (power_policy_applied_.load(std::memory_order_relaxed) ? "true" : "false") << ","
                << "\"timer_policy_error\":" << power_policy_error_.load(std::memory_order_relaxed) << ","
                << "\"timer_resolution_ms\":" << kTimerResolutionMs << ","
                << "\"timer_resolution_request_succeeded\":"
                << (timer_begin_succeeded_.load(std::memory_order_relaxed) ? "true" : "false") << ","
                << "\"timer_resolution_result\":" << timer_begin_result_.load(std::memory_order_relaxed)
                << "}";
            return out.str();
        }

      private:
        static constexpr uint32_t kTimerResolutionMs = 1;

        static int64_t fps_to_milli(float value)
        {
            if (!std::isfinite(value))
            {
                return -1;
            }
            return static_cast<int64_t>(std::llround(static_cast<double>(value) * 1000.0));
        }

        static void append_optional_fps(std::ostringstream& out, int64_t milli_fps)
        {
            if (milli_fps < 0)
            {
                out << "null";
            }
            else
            {
                out << static_cast<double>(milli_fps) / 1000.0;
            }
        }

        bool enabled_ = true;
        TargetFpsConfig target_config_{};
        std::atomic<bool> started_{false};
        std::atomic<bool> power_policy_attempted_{false};
        std::atomic<bool> power_policy_applied_{false};
        std::atomic<uint32_t> power_policy_error_{0};
        std::atomic<uint32_t> timer_begin_result_{0};
        std::atomic<bool> timer_begin_succeeded_{false};
        std::atomic<bool> timer_active_{false};
        std::atomic<bool> target_attempted_{false};
        std::atomic<bool> target_applied_{false};
        std::atomic<TargetOverrideResult> target_result_{TargetOverrideResult::NotAttempted};
        std::atomic<uint32_t> target_exception_code_{0};
        std::atomic<bool> layout_calibrated_{false};
        std::atomic<int32_t> layout_adjustment_bytes_{0};
        std::atomic<bool> entry_signatures_valid_{false};
        std::atomic<int64_t> previous_max_fps_milli_{-1};
        std::atomic<int64_t> previous_max_tick_rate_milli_{-1};
        std::atomic<int64_t> observed_max_fps_milli_{-1};
        std::atomic<int64_t> observed_max_tick_rate_milli_{-1};
    };

    FramePacingPolicy g_frame_pacing;

    struct WindowSnapshot
    {
        uint64_t samples = 0;
        uint64_t idle_samples = 0;
        uint64_t delta_us_sum = 0;
        uint64_t delta_us_max = 0;
        uint64_t delta_us_last = 0;
        uint64_t slow_16 = 0;
        uint64_t slow_33 = 0;
        uint64_t slow_50 = 0;
        uint64_t slow_100 = 0;
    };

    struct FrameSpike
    {
        uint64_t sequence = 0;
        uint64_t observed_at_unix_ms = 0;
        uint64_t sample = 0;
        uint64_t delta_us = 0;
        bool idle = false;
        uint64_t slow_16_total = 0;
        uint64_t slow_33_total = 0;
        uint64_t slow_50_total = 0;
        uint64_t slow_100_total = 0;
    };

    class FrameSampler
    {
      public:
        FrameSampler() : output_path_(default_output_path()), started_at_ms_(unix_time_ms()), enabled_(env_enabled())
        {
        }

        ~FrameSampler()
        {
            stop();
        }

        void start()
        {
            if (!enabled())
            {
                return;
            }
            bool expected = false;
            if (!running_.compare_exchange_strong(expected, true))
            {
                return;
            }
            writer_ = std::thread([this]() { writer_loop(); });
        }

        void stop()
        {
            if (!running_.exchange(false))
            {
                return;
            }
            cv_.notify_all();
            if (writer_.joinable())
            {
                writer_.join();
            }
        }

        void mark_hook_registered()
        {
            hook_registered_.store(true, std::memory_order_relaxed);
        }

        void observe(float delta_seconds, bool idle)
        {
            if (!enabled_)
            {
                return;
            }

            const uint64_t delta_us = delta_to_microseconds(delta_seconds);
            const uint64_t sample = samples_total_.fetch_add(1, std::memory_order_relaxed) + 1;
            delta_us_sum_total_.fetch_add(delta_us, std::memory_order_relaxed);
            last_delta_us_.store(delta_us, std::memory_order_relaxed);
            atomic_max(max_delta_us_total_, delta_us);

            window_samples_.fetch_add(1, std::memory_order_relaxed);
            window_delta_us_sum_.fetch_add(delta_us, std::memory_order_relaxed);
            window_last_delta_us_.store(delta_us, std::memory_order_relaxed);
            atomic_max(window_max_delta_us_, delta_us);

            if (idle)
            {
                idle_samples_total_.fetch_add(1, std::memory_order_relaxed);
                window_idle_samples_.fetch_add(1, std::memory_order_relaxed);
            }
            if (delta_us >= kSlow16ThresholdUs)
            {
                slow_16_total_.fetch_add(1, std::memory_order_relaxed);
                window_slow_16_.fetch_add(1, std::memory_order_relaxed);
            }
            if (delta_us >= kSlow33ThresholdUs)
            {
                slow_33_total_.fetch_add(1, std::memory_order_relaxed);
                window_slow_33_.fetch_add(1, std::memory_order_relaxed);
            }
            if (delta_us >= kSlow50ThresholdUs)
            {
                slow_50_total_.fetch_add(1, std::memory_order_relaxed);
                window_slow_50_.fetch_add(1, std::memory_order_relaxed);
            }
            if (delta_us >= kSlow100ThresholdUs)
            {
                slow_100_total_.fetch_add(1, std::memory_order_relaxed);
                window_slow_100_.fetch_add(1, std::memory_order_relaxed);
                record_spike(delta_us, idle, sample);
            }
        }

        std::string status_json(WindowSnapshot window) const
        {
            const uint64_t samples = samples_total_.load(std::memory_order_relaxed);
            const uint64_t sum = delta_us_sum_total_.load(std::memory_order_relaxed);
            const uint64_t last = last_delta_us_.load(std::memory_order_relaxed);
            const uint64_t max = max_delta_us_total_.load(std::memory_order_relaxed);
            const double avg_ms = samples > 0 ? us_to_ms(sum) / static_cast<double>(samples) : 0.0;
            const double window_avg_ms =
                window.samples > 0 ? us_to_ms(window.delta_us_sum) / static_cast<double>(window.samples) : 0.0;
            const double window_fps = window_avg_ms > 0.0 ? 1000.0 / window_avg_ms : 0.0;

            std::ostringstream out;
            out.setf(std::ios::fixed);
            out.precision(3);
            out << "{"
                << "\"schema_version\":2,"
                << "\"source\":\"BMFFrameTelemetry\","
                << "\"enabled\":" << (enabled_ ? "true" : "false") << ","
                << "\"hook_registered\":" << (hook_registered_.load(std::memory_order_relaxed) ? "true" : "false") << ","
                << "\"pid\":" << GetCurrentProcessId() << ","
                << "\"started_at_unix_ms\":" << started_at_ms_ << ","
                << "\"updated_at_unix_ms\":" << unix_time_ms() << ","
                << "\"path\":\"" << json_escape(output_path_.string()) << "\","
                << "\"pacing\":" << g_frame_pacing.status_json() << ","
                << "\"window\":{"
                << "\"samples\":" << window.samples << ","
                << "\"idle_samples\":" << window.idle_samples << ","
                << "\"delta_ms_sum\":" << us_to_ms(window.delta_us_sum) << ","
                << "\"delta_ms_avg\":" << window_avg_ms << ","
                << "\"delta_ms_max\":" << us_to_ms(window.delta_us_max) << ","
                << "\"delta_ms_last\":" << us_to_ms(window.delta_us_last) << ","
                << "\"fps_avg\":" << window_fps << ","
                << "\"slow_16_67\":" << window.slow_16 << ","
                << "\"slow_33_33\":" << window.slow_33 << ","
                << "\"slow_50\":" << window.slow_50 << ","
                << "\"slow_100\":" << window.slow_100
                << "},"
                << "\"lifetime\":{"
                << "\"samples_total\":" << samples << ","
                << "\"idle_samples_total\":" << idle_samples_total_.load(std::memory_order_relaxed) << ","
                << "\"delta_ms_sum_total\":" << us_to_ms(sum) << ","
                << "\"delta_ms_avg\":" << avg_ms << ","
                << "\"delta_ms_max\":" << us_to_ms(max) << ","
                << "\"delta_ms_last\":" << us_to_ms(last) << ","
                << "\"slow_16_67_total\":" << slow_16_total_.load(std::memory_order_relaxed) << ","
                << "\"slow_33_33_total\":" << slow_33_total_.load(std::memory_order_relaxed) << ","
                << "\"slow_50_total\":" << slow_50_total_.load(std::memory_order_relaxed) << ","
                << "\"slow_100_total\":" << slow_100_total_.load(std::memory_order_relaxed)
                << "},"
                << "\"spikes\":" << spikes_json()
                << "}\n";
            return out.str();
        }

      private:
        bool enabled() const
        {
            return enabled_;
        }

        WindowSnapshot take_window_snapshot()
        {
            WindowSnapshot snapshot;
            snapshot.samples = window_samples_.exchange(0, std::memory_order_relaxed);
            snapshot.idle_samples = window_idle_samples_.exchange(0, std::memory_order_relaxed);
            snapshot.delta_us_sum = window_delta_us_sum_.exchange(0, std::memory_order_relaxed);
            snapshot.delta_us_max = window_max_delta_us_.exchange(0, std::memory_order_relaxed);
            snapshot.delta_us_last = window_last_delta_us_.load(std::memory_order_relaxed);
            snapshot.slow_16 = window_slow_16_.exchange(0, std::memory_order_relaxed);
            snapshot.slow_33 = window_slow_33_.exchange(0, std::memory_order_relaxed);
            snapshot.slow_50 = window_slow_50_.exchange(0, std::memory_order_relaxed);
            snapshot.slow_100 = window_slow_100_.exchange(0, std::memory_order_relaxed);
            return snapshot;
        }

        static std::string spike_json(const FrameSpike& spike)
        {
            std::ostringstream out;
            out.setf(std::ios::fixed);
            out.precision(3);
            out << "{"
                << "\"sequence\":" << spike.sequence << ","
                << "\"observed_at_unix_ms\":" << spike.observed_at_unix_ms << ","
                << "\"sample\":" << spike.sample << ","
                << "\"delta_ms\":" << us_to_ms(spike.delta_us) << ","
                << "\"idle\":" << (spike.idle ? "true" : "false") << ","
                << "\"slow_16_67_total\":" << spike.slow_16_total << ","
                << "\"slow_33_33_total\":" << spike.slow_33_total << ","
                << "\"slow_50_total\":" << spike.slow_50_total << ","
                << "\"slow_100_total\":" << spike.slow_100_total
                << "}";
            return out.str();
        }

        std::string spikes_json() const
        {
            std::lock_guard lock(spike_mutex_);
            std::ostringstream out;
            out.setf(std::ios::fixed);
            out.precision(3);
            out << "{"
                << "\"threshold_ms\":" << us_to_ms(kSlow100ThresholdUs) << ","
                << "\"total\":" << spike_sequence_ << ","
                << "\"last\":";
            if (spike_sequence_ > 0)
            {
                out << spike_json(last_spike_);
            }
            else
            {
                out << "null";
            }
            out << ",\"recent\":[";
            const uint64_t first_sequence =
                spike_sequence_ > recent_spike_count_ ? spike_sequence_ - recent_spike_count_ + 1 : 1;
            bool first = true;
            for (uint64_t sequence = first_sequence; sequence <= spike_sequence_; ++sequence)
            {
                const size_t index = static_cast<size_t>((sequence - 1) % recent_spikes_.size());
                const FrameSpike& spike = recent_spikes_[index];
                if (spike.sequence != sequence)
                {
                    continue;
                }
                if (!first)
                {
                    out << ",";
                }
                first = false;
                out << spike_json(spike);
            }
            out << "]}";
            return out.str();
        }

        void record_spike(uint64_t delta_us, bool idle, uint64_t sample)
        {
            std::lock_guard lock(spike_mutex_);
            const uint64_t sequence = spike_sequence_ + 1;
            FrameSpike spike;
            spike.sequence = sequence;
            spike.observed_at_unix_ms = unix_time_ms();
            spike.sample = sample;
            spike.delta_us = delta_us;
            spike.idle = idle;
            spike.slow_16_total = slow_16_total_.load(std::memory_order_relaxed);
            spike.slow_33_total = slow_33_total_.load(std::memory_order_relaxed);
            spike.slow_50_total = slow_50_total_.load(std::memory_order_relaxed);
            spike.slow_100_total = slow_100_total_.load(std::memory_order_relaxed);

            const size_t index = static_cast<size_t>((sequence - 1) % recent_spikes_.size());
            recent_spikes_[index] = spike;
            last_spike_ = spike;
            spike_sequence_ = sequence;
            if (recent_spike_count_ < recent_spikes_.size())
            {
                ++recent_spike_count_;
            }
        }

        void writer_loop()
        {
            while (running_.load())
            {
                std::unique_lock lock(cv_mutex_);
                cv_.wait_for(lock, std::chrono::seconds(1), [this]() { return !running_.load(); });
                if (!running_.load())
                {
                    break;
                }
                write_snapshot();
            }
            write_snapshot();
        }

        void write_snapshot()
        {
            try
            {
                std::filesystem::create_directories(output_path_.parent_path());
                const auto tmp_path = output_path_.wstring() + L".tmp";
                {
                    std::ofstream file(std::filesystem::path(tmp_path), std::ios::out | std::ios::trunc);
                    file << status_json(take_window_snapshot());
                }
                std::error_code ignored;
                std::filesystem::remove(output_path_, ignored);
                std::filesystem::rename(tmp_path, output_path_);
            }
            catch (const std::exception& error)
            {
                std::printf("[BMFFrameTelemetry] write failed: %s\n", error.what());
            }
        }

        std::filesystem::path output_path_;
        uint64_t started_at_ms_ = 0;
        bool enabled_ = true;
        std::atomic<bool> running_{false};
        std::atomic<bool> hook_registered_{false};
        std::thread writer_;
        std::mutex cv_mutex_;
        std::condition_variable cv_;
        mutable std::mutex spike_mutex_;
        std::array<FrameSpike, 32> recent_spikes_{};
        size_t recent_spike_count_ = 0;
        uint64_t spike_sequence_ = 0;
        FrameSpike last_spike_{};

        std::atomic<uint64_t> samples_total_{0};
        std::atomic<uint64_t> idle_samples_total_{0};
        std::atomic<uint64_t> delta_us_sum_total_{0};
        std::atomic<uint64_t> max_delta_us_total_{0};
        std::atomic<uint64_t> last_delta_us_{0};
        std::atomic<uint64_t> slow_16_total_{0};
        std::atomic<uint64_t> slow_33_total_{0};
        std::atomic<uint64_t> slow_50_total_{0};
        std::atomic<uint64_t> slow_100_total_{0};

        std::atomic<uint64_t> window_samples_{0};
        std::atomic<uint64_t> window_idle_samples_{0};
        std::atomic<uint64_t> window_delta_us_sum_{0};
        std::atomic<uint64_t> window_max_delta_us_{0};
        std::atomic<uint64_t> window_last_delta_us_{0};
        std::atomic<uint64_t> window_slow_16_{0};
        std::atomic<uint64_t> window_slow_33_{0};
        std::atomic<uint64_t> window_slow_50_{0};
        std::atomic<uint64_t> window_slow_100_{0};
    };

    FrameSampler g_sampler;

    class BMFFrameTelemetryMod : public CppUserModBase
    {
      public:
        BMFFrameTelemetryMod() : CppUserModBase()
        {
            ModName = STR("BMFFrameTelemetry");
            ModVersion = STR("0.1.0");
            ModDescription = STR("Native server frame pacing and engine tick telemetry for BMF");
            ModAuthors = STR("CityRPG/BMF");
            g_frame_pacing.start();
            g_sampler.start();
            std::printf("[BMFFrameTelemetry] loaded\n");
        }

        ~BMFFrameTelemetryMod() override
        {
            g_sampler.stop();
            g_frame_pacing.stop();
        }

        auto on_unreal_init() -> void override
        {
            if (g_frame_pacing.should_apply_target())
            {
                Unreal::Hook::RegisterEngineTickPreCallback(
                    [](Unreal::Hook::TCallbackIterationData<void>&, Unreal::UEngine* engine, float, bool) {
                        g_frame_pacing.apply_target_once(engine);
                    },
                    {true, false, STR("BMFFrameTelemetry"), STR("FramePacingTarget")});
                std::printf("[BMFFrameTelemetry] one-shot frame target callback registered\n");
            }
            Unreal::Hook::RegisterEngineTickPostCallback(
                [](Unreal::Hook::TCallbackIterationData<void>&, Unreal::UEngine*, float delta_seconds, bool idle) {
                    g_sampler.observe(delta_seconds, idle);
                },
                {false, false, STR("BMFFrameTelemetry"), STR("EngineTickSampler")});
            g_sampler.mark_hook_registered();
            std::printf("[BMFFrameTelemetry] engine tick callback registered\n");
        }
    };
} // namespace

extern "C"
{
    __declspec(dllexport) CppUserModBase* start_mod()
    {
        return new BMFFrameTelemetryMod();
    }

    __declspec(dllexport) void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
