#pragma once

#include <string>
#include <atomic>
#include <thread>
#include <functional>
#include <nlohmann/json.hpp>
#include <ixwebsocket/IXWebSocket.h>

using json = nlohmann::json;

class PhoenixClient {
public:
    using CommandCallback = std::function<void(const std::string&, const json&)>;

    PhoenixClient(const std::string& url, const std::string& token);
    ~PhoenixClient();

    // Connect, join channel, and start heartbeat. Blocks until joined or throws.
    void connect();

    // Push a detection batch to ingestion:lobby
    void push_detections(int cam_id, const json& payload);

    // Register a callback for incoming pipeline commands (e.g. set_thumbnails)
    void set_command_callback(CommandCallback cb) { command_callback_ = std::move(cb); }

    // Disconnect
    void close();

    bool is_connected() const { return joined_.load(); }

private:
    void on_message(const ix::WebSocketMessagePtr& msg);
    void send(const std::string& event, const std::string& topic, const json& payload);
    void heartbeat_loop();

    std::string url_;
    std::string token_;
    ix::WebSocket ws_;
    std::atomic<int> ref_{0};
    std::atomic<bool> joined_{false};
    std::atomic<bool> running_{false};
    std::thread heartbeat_thread_;
    int push_count_ = 0;

    // Synchronization for join reply
    std::mutex join_mtx_;
    std::condition_variable join_cv_;
    bool join_received_ = false;
    bool join_ok_ = false;
    CommandCallback command_callback_;

    static constexpr int HEARTBEAT_INTERVAL_SEC = 30;
};
