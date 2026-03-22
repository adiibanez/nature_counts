#pragma once

#include <nlohmann/json.hpp>
#include <string>

using json = nlohmann::json;

// Write a tracker YAML config file by reading a preset base file
// and overriding individual parameters from the JSON payload.
// Returns true on success.
bool write_tracker_yaml(const json& params,
                        const std::string& config_dir,
                        const std::string& output_path);
