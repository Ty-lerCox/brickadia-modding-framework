#define WIN32_LEAN_AND_MEAN

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <Mod/CppUserModBase.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

using namespace RC;

namespace
{
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
                if (static_cast<unsigned char>(ch) < 0x20)
                {
                    out += '?';
                }
                else
                {
                    out += ch;
                }
                break;
            }
        }
        return out;
    }

    bool send_all(SOCKET socket, const std::string& data)
    {
        const char* cursor = data.data();
        int remaining = static_cast<int>(data.size());
        while (remaining > 0)
        {
            const int sent = ::send(socket, cursor, remaining, 0);
            if (sent <= 0)
            {
                return false;
            }
            cursor += sent;
            remaining -= sent;
        }
        return true;
    }

    class SocketRuntime
    {
      public:
        bool start(std::string host, uint16_t port, std::string token)
        {
            if (port == 0)
            {
                set_error("port must be greater than zero");
                return false;
            }

            {
                std::lock_guard lock(config_mutex_);
                host_ = std::move(host);
                port_ = port;
                token_ = std::move(token);
            }

            bool expected = false;
            if (!running_.compare_exchange_strong(expected, true))
            {
                return true;
            }

            worker_ = std::thread([this]() { worker_loop(); });
            return true;
        }

        void stop()
        {
            if (!running_.exchange(false))
            {
                return;
            }

            outbound_cv_.notify_all();
            if (worker_.joinable())
            {
                worker_.join();
            }
            connected_.store(false);
        }

        bool send_line(std::string line)
        {
            if (!running_.load())
            {
                set_error("socket runtime is not running");
                return false;
            }
            if (line.empty() || line.back() != '\n')
            {
                line.push_back('\n');
            }
            {
                std::lock_guard lock(outbound_mutex_);
                outbound_.push_back(std::move(line));
            }
            outbound_cv_.notify_one();
            return true;
        }

        std::vector<std::string> receive_lines(size_t max_count)
        {
            std::vector<std::string> lines;
            if (max_count == 0)
            {
                return lines;
            }
            std::lock_guard lock(inbound_mutex_);
            while (!inbound_.empty() && lines.size() < max_count)
            {
                lines.push_back(std::move(inbound_.front()));
                inbound_.pop_front();
            }
            return lines;
        }

        std::string status_json()
        {
            std::lock_guard config_lock(config_mutex_);
            std::lock_guard error_lock(error_mutex_);
            std::lock_guard in_lock(inbound_mutex_);
            std::lock_guard out_lock(outbound_mutex_);
            std::ostringstream out;
            out << "{"
                << "\"running\":" << (running_.load() ? "true" : "false") << ","
                << "\"connected\":" << (connected_.load() ? "true" : "false") << ","
                << "\"host\":\"" << json_escape(host_) << "\","
                << "\"port\":" << port_ << ","
                << "\"inboundQueued\":" << inbound_.size() << ","
                << "\"outboundQueued\":" << outbound_.size() << ","
                << "\"connects\":" << connects_.load() << ","
                << "\"disconnects\":" << disconnects_.load() << ","
                << "\"sentLines\":" << sent_lines_.load() << ","
                << "\"receivedLines\":" << received_lines_.load() << ","
                << "\"lastError\":\"" << json_escape(last_error_) << "\""
                << "}";
            return out.str();
        }

      private:
        void worker_loop()
        {
            WSADATA wsa_data{};
            const int wsa_result = ::WSAStartup(MAKEWORD(2, 2), &wsa_data);
            if (wsa_result != 0)
            {
                set_error("WSAStartup failed: " + std::to_string(wsa_result));
                running_.store(false);
                return;
            }

            while (running_.load())
            {
                SOCKET socket = connect_once();
                if (socket == INVALID_SOCKET)
                {
                    reconnect_pause();
                    continue;
                }

                connected_.store(true);
                connects_.fetch_add(1);
                set_error("");
                send_hello(socket);
                socket_loop(socket);
                ::closesocket(socket);
                connected_.store(false);
                disconnects_.fetch_add(1);
                reconnect_pause();
            }

            ::WSACleanup();
        }

        SOCKET connect_once()
        {
            std::string host;
            uint16_t port = 0;
            {
                std::lock_guard lock(config_mutex_);
                host = host_;
                port = port_;
            }

            addrinfo hints{};
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_STREAM;
            hints.ai_protocol = IPPROTO_TCP;

            addrinfo* result = nullptr;
            const std::string port_text = std::to_string(port);
            const int getaddr_result = ::getaddrinfo(host.c_str(), port_text.c_str(), &hints, &result);
            if (getaddr_result != 0)
            {
                set_error("getaddrinfo failed: " + std::to_string(getaddr_result));
                return INVALID_SOCKET;
            }

            SOCKET connected_socket = INVALID_SOCKET;
            for (addrinfo* ptr = result; ptr != nullptr; ptr = ptr->ai_next)
            {
                SOCKET candidate = ::socket(ptr->ai_family, ptr->ai_socktype, ptr->ai_protocol);
                if (candidate == INVALID_SOCKET)
                {
                    continue;
                }
                if (::connect(candidate, ptr->ai_addr, static_cast<int>(ptr->ai_addrlen)) == 0)
                {
                    connected_socket = candidate;
                    break;
                }
                ::closesocket(candidate);
            }
            ::freeaddrinfo(result);

            if (connected_socket == INVALID_SOCKET)
            {
                set_error("connect failed: " + std::to_string(::WSAGetLastError()));
                return INVALID_SOCKET;
            }

            BOOL no_delay = TRUE;
            ::setsockopt(connected_socket, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&no_delay), sizeof(no_delay));
            return connected_socket;
        }

        void send_hello(SOCKET socket)
        {
            std::string token;
            {
                std::lock_guard lock(config_mutex_);
                token = token_;
            }
            const std::string hello =
                std::string("{\"type\":\"hello\",\"role\":\"bmf-native\",\"source\":\"BMFSocket\",\"version\":\"0.1.0\",\"token\":\"") +
                json_escape(token) +
                "\"}\n";
            send_all(socket, hello);
        }

        void socket_loop(SOCKET socket)
        {
            std::string read_buffer;
            while (running_.load())
            {
                if (!drain_outbound(socket))
                {
                    return;
                }

                fd_set read_set;
                FD_ZERO(&read_set);
                FD_SET(socket, &read_set);
                timeval timeout{};
                timeout.tv_sec = 0;
                timeout.tv_usec = 50000;
                const int selected = ::select(0, &read_set, nullptr, nullptr, &timeout);
                if (selected == SOCKET_ERROR)
                {
                    set_error("select failed: " + std::to_string(::WSAGetLastError()));
                    return;
                }
                if (selected == 0)
                {
                    continue;
                }

                char buffer[4096];
                const int received = ::recv(socket, buffer, sizeof(buffer), 0);
                if (received <= 0)
                {
                    if (received < 0)
                    {
                        set_error("recv failed: " + std::to_string(::WSAGetLastError()));
                    }
                    return;
                }
                read_buffer.append(buffer, static_cast<size_t>(received));
                consume_read_buffer(read_buffer);
            }
        }

        bool drain_outbound(SOCKET socket)
        {
            std::deque<std::string> batch;
            {
                std::lock_guard lock(outbound_mutex_);
                batch.swap(outbound_);
            }

            for (const std::string& line : batch)
            {
                if (!send_all(socket, line))
                {
                    set_error("send failed: " + std::to_string(::WSAGetLastError()));
                    std::lock_guard lock(outbound_mutex_);
                    outbound_.push_front(line);
                    return false;
                }
                sent_lines_.fetch_add(1);
            }
            return true;
        }

        void consume_read_buffer(std::string& buffer)
        {
            for (;;)
            {
                const size_t newline = buffer.find('\n');
                if (newline == std::string::npos)
                {
                    return;
                }
                std::string line = buffer.substr(0, newline);
                buffer.erase(0, newline + 1);
                if (!line.empty() && line.back() == '\r')
                {
                    line.pop_back();
                }
                if (!line.empty())
                {
                    push_inbound(std::move(line));
                    received_lines_.fetch_add(1);
                }
            }
        }

        void push_inbound(std::string line)
        {
            std::lock_guard lock(inbound_mutex_);
            inbound_.push_back(std::move(line));
            while (inbound_.size() > 4096)
            {
                inbound_.pop_front();
            }
        }

        void reconnect_pause()
        {
            for (int index = 0; running_.load() && index < 10; ++index)
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
            }
        }

        void set_error(std::string value)
        {
            std::lock_guard lock(error_mutex_);
            last_error_ = std::move(value);
        }

        std::mutex config_mutex_;
        std::string host_ = "127.0.0.1";
        uint16_t port_ = 0;
        std::string token_;

        std::mutex inbound_mutex_;
        std::deque<std::string> inbound_;
        std::mutex outbound_mutex_;
        std::condition_variable outbound_cv_;
        std::deque<std::string> outbound_;

        std::mutex error_mutex_;
        std::string last_error_;

        std::thread worker_;
        std::atomic<bool> running_{false};
        std::atomic<bool> connected_{false};
        std::atomic<uint64_t> connects_{0};
        std::atomic<uint64_t> disconnects_{0};
        std::atomic<uint64_t> sent_lines_{0};
        std::atomic<uint64_t> received_lines_{0};
    };

    SocketRuntime g_socket;

    int lua_socket_start(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        const int argc = lua_gettop(state);
        std::string host = "127.0.0.1";
        if (argc >= 1 && lua_isstring(state, 1))
        {
            host = std::string(lua_tostring(state, 1));
        }
        int64_t port = 0;
        if (argc >= 2 && lua_isnumber(state, 2))
        {
            port = static_cast<int64_t>(lua_tointeger(state, 2));
        }
        std::string token;
        if (argc >= 3 && lua_isstring(state, 3))
        {
            token = std::string(lua_tostring(state, 3));
        }

        const bool ok = port > 0 && port <= 65535 && g_socket.start(host, static_cast<uint16_t>(port), token);
        lua.set_bool(ok);
        lua.set_string(g_socket.status_json());
        return 2;
    }

    int lua_socket_stop(const LuaMadeSimple::Lua& lua)
    {
        g_socket.stop();
        lua.set_bool(true);
        return 1;
    }

    int lua_socket_send(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        if (!lua_isstring(state, 1))
        {
            lua.set_bool(false);
            return 1;
        }
        size_t line_length = 0;
        const char* line = lua_tolstring(state, 1, &line_length);
        const bool ok = line != nullptr && g_socket.send_line(std::string(line, line_length));
        lua.set_bool(ok);
        return 1;
    }

    int lua_socket_receive(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        int64_t max_count = 64;
        if (lua_isnumber(state, 1))
        {
            max_count = static_cast<int64_t>(lua_tointeger(state, 1));
        }
        if (max_count < 1)
        {
            max_count = 1;
        }
        if (max_count > 512)
        {
            max_count = 512;
        }

        const auto lines = g_socket.receive_lines(static_cast<size_t>(max_count));
        lua_newtable(state);
        int index = 1;
        for (const std::string& line : lines)
        {
            lua_pushlstring(state, line.data(), line.size());
            lua_rawseti(state, -2, index++);
        }
        return 1;
    }

    int lua_socket_status(const LuaMadeSimple::Lua& lua)
    {
        lua.set_string(g_socket.status_json());
        return 1;
    }

    class BMFSocketMod : public CppUserModBase
    {
      public:
        BMFSocketMod() : CppUserModBase()
        {
            ModName = STR("BMFSocket");
            ModVersion = STR("0.1.0");
            ModDescription = STR("Loopback socket transport for BMF Lua mods");
            ModAuthors = STR("CityRPG/BMF");
            std::printf("[BMFSocket] loaded\n");
        }

        ~BMFSocketMod() override
        {
            g_socket.stop();
        }

        auto on_lua_start(StringViewType,
                          LuaMadeSimple::Lua& lua,
                          LuaMadeSimple::Lua&,
                          LuaMadeSimple::Lua&,
                          LuaMadeSimple::Lua*) -> void override
        {
            lua.register_function("BMFSocketStart", lua_socket_start);
            lua.register_function("BMFSocketStop", lua_socket_stop);
            lua.register_function("BMFSocketSend", lua_socket_send);
            lua.register_function("BMFSocketReceive", lua_socket_receive);
            lua.register_function("BMFSocketStatus", lua_socket_status);
        }
    };
} // namespace

extern "C"
{
    __declspec(dllexport) CppUserModBase* start_mod()
    {
        return new BMFSocketMod();
    }

    __declspec(dllexport) void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
