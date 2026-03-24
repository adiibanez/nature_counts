#pragma once

#include <nlohmann/json.hpp>
#include <queue>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <functional>
#include <vector>
#include <cstdint>

using json = nlohmann::json;

struct ThumbnailJob {
    std::vector<uint8_t> rgba_frame;
    int frame_width;
    int frame_height;
    int source_width;   // original source resolution
    int source_height;
    json detection;     // detection payload (will be enriched with thumbnails)
};

// Thread-safe detection output queue
class DetectionQueue {
public:
    explicit DetectionQueue(size_t max_size = 100);
    bool push(json det);
    bool pop(json& out, int timeout_ms = 1000);
    void clear();

private:
    std::queue<json> queue_;
    std::mutex mtx_;
    std::condition_variable cv_;
    size_t max_size_;
};

// Background thumbnail worker
class ThumbnailWorker {
public:
    ThumbnailWorker(DetectionQueue& output_queue, int thumb_size = 96);
    ~ThumbnailWorker();

    void start();
    void stop();

    // Submit a job (non-blocking, drops if overloaded)
    bool submit(ThumbnailJob job);

private:
    void run();

    struct CropResult {
        std::string thumbnail;  // base64 JPEG (empty if skipped)
        double sharpness = 0.0; // Laplacian variance
    };

    CropResult crop_thumbnail(const uint8_t* frame, int fw, int fh,
                              double left, double top, double width, double height);

    DetectionQueue& output_queue_;
    int thumb_size_;

    std::queue<ThumbnailJob> jobs_;
    std::mutex mtx_;
    std::condition_variable cv_;
    std::thread thread_;
    bool running_ = false;
    static constexpr size_t MAX_JOBS = 10;
};

// Global detection output queue (consumed by Phoenix pusher)
extern DetectionQueue g_detection_queue;
