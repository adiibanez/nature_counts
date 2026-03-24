#include "thumbnail.h"
#include "probes.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>
#include <algorithm>
#include <cstring>

// Base64 encoding (no external dependency needed)
static const char B64_TABLE[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static std::string base64_encode(const uint8_t* data, size_t len) {
    std::string out;
    out.reserve(((len + 2) / 3) * 4);
    for (size_t i = 0; i < len; i += 3) {
        uint32_t n = static_cast<uint32_t>(data[i]) << 16;
        if (i + 1 < len) n |= static_cast<uint32_t>(data[i + 1]) << 8;
        if (i + 2 < len) n |= static_cast<uint32_t>(data[i + 2]);
        out.push_back(B64_TABLE[(n >> 18) & 0x3F]);
        out.push_back(B64_TABLE[(n >> 12) & 0x3F]);
        out.push_back((i + 1 < len) ? B64_TABLE[(n >> 6) & 0x3F] : '=');
        out.push_back((i + 2 < len) ? B64_TABLE[n & 0x3F] : '=');
    }
    return out;
}

// --- DetectionQueue ---

DetectionQueue g_detection_queue(100);

DetectionQueue::DetectionQueue(size_t max_size) : max_size_(max_size) {}

bool DetectionQueue::push(json det) {
    std::lock_guard<std::mutex> lk(mtx_);
    if (queue_.size() >= max_size_) return false;
    queue_.push(std::move(det));
    cv_.notify_one();
    return true;
}

bool DetectionQueue::pop(json& out, int timeout_ms) {
    std::unique_lock<std::mutex> lk(mtx_);
    if (!cv_.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                      [&] { return !queue_.empty(); }))
        return false;
    out = std::move(queue_.front());
    queue_.pop();
    return true;
}

void DetectionQueue::clear() {
    std::lock_guard<std::mutex> lk(mtx_);
    while (!queue_.empty()) queue_.pop();
}

// --- ThumbnailWorker ---

ThumbnailWorker::ThumbnailWorker(DetectionQueue& output_queue, int thumb_size)
    : output_queue_(output_queue), thumb_size_(thumb_size) {}

ThumbnailWorker::~ThumbnailWorker() { stop(); }

void ThumbnailWorker::start() {
    running_ = true;
    thread_ = std::thread(&ThumbnailWorker::run, this);
}

void ThumbnailWorker::stop() {
    {
        std::lock_guard<std::mutex> lk(mtx_);
        running_ = false;
    }
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
}

bool ThumbnailWorker::submit(ThumbnailJob job) {
    std::lock_guard<std::mutex> lk(mtx_);
    if (jobs_.size() >= MAX_JOBS) return false;
    jobs_.push(std::move(job));
    cv_.notify_one();
    return true;
}

void ThumbnailWorker::run() {
    while (true) {
        ThumbnailJob job;
        {
            std::unique_lock<std::mutex> lk(mtx_);
            cv_.wait_for(lk, std::chrono::seconds(2),
                         [&] { return !jobs_.empty() || !running_; });
            if (!running_ && jobs_.empty()) break;
            if (jobs_.empty()) continue;
            job = std::move(jobs_.front());
            jobs_.pop();
        }

        double sx = (job.source_width > 0)
            ? static_cast<double>(job.frame_width) / job.source_width : 1.0;
        double sy = (job.source_height > 0)
            ? static_cast<double>(job.frame_height) / job.source_height : 1.0;

        int min_area = g_min_crop_area.load(std::memory_order_relaxed);

        auto& objects = job.detection["objects"];
        for (auto& obj : objects) {
            auto& bbox = obj["bbox"];
            double left = bbox["left"].get<double>() * sx;
            double top = bbox["top"].get<double>() * sy;
            double width = bbox["width"].get<double>() * sx;
            double height = bbox["height"].get<double>() * sy;

            // Skip thumbnail for crops below minimum area
            if (static_cast<int>(width * height) < min_area)
                continue;

            auto result = crop_thumbnail(
                job.rgba_frame.data(), job.frame_width, job.frame_height,
                left, top, width, height);

            obj["sharpness"] = result.sharpness;
            if (!result.thumbnail.empty())
                obj["thumbnail"] = result.thumbnail;
        }

        output_queue_.push(std::move(job.detection));
    }
}

ThumbnailWorker::CropResult ThumbnailWorker::crop_thumbnail(
    const uint8_t* frame, int fw, int fh,
    double left, double top, double width, double height)
{
    CropResult result;

    int x1 = std::max(0, static_cast<int>(left));
    int y1 = std::max(0, static_cast<int>(top));
    int x2 = std::min(fw, static_cast<int>(left + width));
    int y2 = std::min(fh, static_cast<int>(top + height));
    if (x2 <= x1 || y2 <= y1) return result;

    // Wrap full RGBA frame (no copy — we own the data in the job)
    cv::Mat rgba(fh, fw, CV_8UC4, const_cast<uint8_t*>(frame));
    cv::Mat crop = rgba(cv::Rect(x1, y1, x2 - x1, y2 - y1));

    cv::Mat bgr;
    cv::cvtColor(crop, bgr, cv::COLOR_RGBA2BGR);

    // Compute sharpness (Laplacian variance on grayscale)
    cv::Mat gray, laplacian;
    cv::cvtColor(bgr, gray, cv::COLOR_BGR2GRAY);
    cv::Laplacian(gray, laplacian, CV_64F);
    cv::Scalar mu, sigma;
    cv::meanStdDev(laplacian, mu, sigma);
    result.sharpness = sigma.val[0] * sigma.val[0];  // variance

    // Skip thumbnail encoding if below sharpness threshold
    double min_sharp = g_min_sharpness.load(std::memory_order_relaxed);
    if (min_sharp > 0.0 && result.sharpness < min_sharp)
        return result;

    int h = bgr.rows, w = bgr.cols;
    double scale = std::min(static_cast<double>(thumb_size_) / std::max(h, w), 1.0);
    if (scale < 1.0)
        cv::resize(bgr, bgr, cv::Size(static_cast<int>(w * scale),
                                       static_cast<int>(h * scale)));

    std::vector<uint8_t> jpg;
    std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, 60};
    if (!cv::imencode(".jpg", bgr, jpg, params)) return result;

    result.thumbnail = base64_encode(jpg.data(), jpg.size());
    return result;
}
