#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <Mod/CppUserModBase.hpp>
#include <UEngine.hpp>
#include <Unreal/Hooks/Hooks.hpp>

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
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
        std::string text = getenv_narrow("BMF_FRAME_TELEMETRY_ENABLED");
        if (text.empty())
        {
            return true;
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
                << "\"schema_version\":1,"
                << "\"source\":\"BMFFrameTelemetry\","
                << "\"enabled\":" << (enabled_ ? "true" : "false") << ","
                << "\"hook_registered\":" << (hook_registered_.load(std::memory_order_relaxed) ? "true" : "false") << ","
                << "\"pid\":" << GetCurrentProcessId() << ","
                << "\"started_at_unix_ms\":" << started_at_ms_ << ","
                << "\"updated_at_unix_ms\":" << unix_time_ms() << ","
                << "\"path\":\"" << json_escape(output_path_.string()) << "\","
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
            ModDescription = STR("Native engine tick frame-time sampler for BMF metrics");
            ModAuthors = STR("CityRPG/BMF");
            g_sampler.start();
            std::printf("[BMFFrameTelemetry] loaded\n");
        }

        ~BMFFrameTelemetryMod() override
        {
            g_sampler.stop();
        }

        auto on_unreal_init() -> void override
        {
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
