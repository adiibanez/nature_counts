#include "phoenix_client.h"
#include <stdexcept>
#include <cstdio>

#define LOG(fmt, ...) fprintf(stderr, "[PhoenixClient] " fmt "\n", ##__VA_ARGS__)

PhoenixClient::PhoenixClient(const std::string& url, const std::string& token)
    : url_(url), token_(token) {}

PhoenixClient::~PhoenixClient() { close(); }

void PhoenixClient::connect() {
    close();

    std::string full_url = url_ + "?token=" + token_ + "&vsn=2.0.0";
    LOG("Connecting to %s", full_url.c_str());

    ws_.setUrl(full_url);
    ws_.setPingInterval(20);
    ws_.disablePerMessageDeflate();

    // Set extra headers — empty Origin avoids Phoenix check_origin rejection
    ix::WebSocketHttpHeaders headers;
    headers["Origin"] = "";
    ws_.setExtraHeaders(headers);

    ws_.setOnMessageCallback([this](const ix::WebSocketMessagePtr& msg) {
        on_message(msg);
    });

    ws_.start();

    // Wait for connection
    for (int i = 0; i < 50; ++i) {
        if (ws_.getReadyState() == ix::ReadyState::Open) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (ws_.getReadyState() != ix::ReadyState::Open)
        throw std::runtime_error("WebSocket connection timeout");

    // Join ingestion:lobby
    ref_ = 0;
    joined_ = false;
    join_received_ = false;
    join_ok_ = false;

    send("phx_join", "ingestion:lobby", json::object());

    // Wait for join reply
    {
        std::unique_lock<std::mutex> lk(join_mtx_);
        if (!join_cv_.wait_for(lk, std::chrono::seconds(5),
                               [this] { return join_received_; }))
            throw std::runtime_error("Join timeout");
        if (!join_ok_)
            throw std::runtime_error("Join rejected by server");
    }

    LOG("Joined ingestion:lobby");
    joined_ = true;
    push_count_ = 0;

    // Start heartbeat
    running_ = true;
    heartbeat_thread_ = std::thread(&PhoenixClient::heartbeat_loop, this);
}

void PhoenixClient::push_detections(int cam_id, const json& payload) {
    if (!joined_)
        throw std::runtime_error("Not connected to Phoenix");

    send("detection_batch", "ingestion:lobby", payload);
    ++push_count_;
    if (push_count_ % 50 == 1) {
        int n_obj = payload.contains("objects") ? static_cast<int>(payload["objects"].size()) : 0;
        LOG("Pushed detection batch #%d (cam %d, %d objects)", push_count_, cam_id, n_obj);
    }
}

void PhoenixClient::close() {
    running_ = false;
    joined_ = false;
    if (heartbeat_thread_.joinable()) heartbeat_thread_.join();
    ws_.stop();
}

void PhoenixClient::on_message(const ix::WebSocketMessagePtr& msg) {
    if (msg->type == ix::WebSocketMessageType::Message) {
        try {
            auto parsed = json::parse(msg->str);
            // Phoenix v2 wire format: [join_ref, ref, topic, event, payload]
            if (parsed.is_array() && parsed.size() >= 5) {
                std::string event = parsed[3].get<std::string>();
                if (event == "phx_reply") {
                    auto& payload = parsed[4];
                    std::lock_guard<std::mutex> lk(join_mtx_);
                    join_received_ = true;
                    join_ok_ = payload.contains("status") &&
                               payload["status"].get<std::string>() == "ok";
                    join_cv_.notify_all();
                }
            }
        } catch (...) {}
    } else if (msg->type == ix::WebSocketMessageType::Error) {
        LOG("WebSocket error: %s", msg->errorInfo.reason.c_str());
    } else if (msg->type == ix::WebSocketMessageType::Close) {
        LOG("WebSocket closed");
        joined_ = false;
    }
}

void PhoenixClient::send(const std::string& event, const std::string& topic,
                          const json& payload)
{
    int r = ++ref_;
    json join_ref = (topic == "ingestion:lobby") ? json("1") : json(nullptr);
    json msg = {join_ref, std::to_string(r), topic, event, payload};
    ws_.send(msg.dump());
}

void PhoenixClient::heartbeat_loop() {
    while (running_) {
        for (int i = 0; i < HEARTBEAT_INTERVAL_SEC * 10 && running_; ++i)
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (!running_) break;

        int r = ++ref_;
        json msg = {nullptr, std::to_string(r), "phoenix", "heartbeat", json::object()};
        ws_.send(msg.dump());
    }
}
