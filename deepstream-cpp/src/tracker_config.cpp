#include "tracker_config.h"

#include <cstdio>
#include <fstream>
#include <regex>
#include <sstream>
#include <unordered_map>

#define LOG(fmt, ...) fprintf(stderr, "[TrackerConfig] " fmt "\n", ##__VA_ARGS__)

static const std::unordered_map<std::string, std::string> preset_files = {
    {"iou",              "config_tracker_IOU.yml"},
    {"nvdcf_accuracy",   "config_tracker_NvDCF_accuracy.yml"},
    {"nvdcf_perf",       "config_tracker_NvDCF_perf.yml"},
    {"nvdcf_max_perf",   "config_tracker_NvDCF_max_perf.yml"},
    {"deepsort",         "config_tracker_DeepSORT.yml"},
};

static std::string read_file(const std::string& path) {
    std::ifstream ifs(path);
    if (!ifs) return "";
    std::ostringstream ss;
    ss << ifs.rdbuf();
    return ss.str();
}

// Replace a YAML scalar value: "  key: old_value" -> "  key: new_value"
// Handles int, float, and simple string values on the same line.
static void replace_yaml_value(std::string& yaml,
                               const std::string& key,
                               const std::string& value) {
    // Match "key:" followed by whitespace and a value, preserving indent/comments
    std::regex re("(\\b" + key + ":\\s*)[^#\\n]*(#.*)?");
    std::string replacement = "$1" + value + "   $2";
    std::string result = std::regex_replace(yaml, re, replacement);
    if (result != yaml) {
        yaml = result;
        LOG("  override: %s = %s", key.c_str(), value.c_str());
    }
}

bool write_tracker_yaml(const json& params,
                        const std::string& config_dir,
                        const std::string& output_path) {
    // Determine preset base file
    std::string preset = params.value("preset", "nvdcf_accuracy");
    auto it = preset_files.find(preset);
    if (it == preset_files.end()) {
        LOG("Unknown preset: %s", preset.c_str());
        return false;
    }

    std::string base_path = config_dir + "/" + it->second;
    std::string yaml = read_file(base_path);
    if (yaml.empty()) {
        LOG("Failed to read base config: %s", base_path.c_str());
        return false;
    }

    LOG("Base preset: %s (%s)", preset.c_str(), base_path.c_str());

    // Apply overrides from the "overrides" object in the payload
    if (params.contains("overrides") && params["overrides"].is_object()) {
        for (auto& [key, val] : params["overrides"].items()) {
            std::string str_val;
            if (val.is_number_float())
                str_val = std::to_string(val.get<double>());
            else if (val.is_number_integer())
                str_val = std::to_string(val.get<int>());
            else
                str_val = val.get<std::string>();

            replace_yaml_value(yaml, key, str_val);
        }
    }

    // Write output
    std::ofstream ofs(output_path);
    if (!ofs) {
        LOG("Failed to write: %s", output_path.c_str());
        return false;
    }
    ofs << yaml;
    LOG("Written to %s", output_path.c_str());
    return true;
}
