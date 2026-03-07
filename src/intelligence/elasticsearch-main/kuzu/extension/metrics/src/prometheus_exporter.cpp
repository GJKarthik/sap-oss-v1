/**
 * Prometheus Metrics Exporter for Kuzu
 * 
 * P1-50: Prometheus Metrics Export
 * 
 * This module provides Prometheus-compatible metrics export for Kuzu,
 * enabling monitoring and alerting of:
 * - Query performance metrics
 * - Index operations (insert, search, delete)
 * - Connection pool statistics
 * - Memory and buffer pool usage
 * - Vector operation latencies
 * 
 * Architecture:
 * ┌────────────────────────────────────────────────────────────────┐
 * │                        Kuzu Engine                             │
 * │  Query ──> Index ──> Storage ──> Buffer ──> Connection         │
 * └────────────────────────────────────────────────────────────────┘
 *                              │
 *                    Metrics Collection
 *                              │
 *                              ▼
 * ┌────────────────────────────────────────────────────────────────┐
 * │                   Prometheus Exporter                          │
 * │  /metrics endpoint ──> Prometheus Server ──> Grafana           │
 * └────────────────────────────────────────────────────────────────┘
 * 
 * Metric Types:
 * - Counter: Monotonically increasing values (requests, errors)
 * - Gauge: Point-in-time values (connections, memory)
 * - Histogram: Distribution of values (latencies)
 * - Summary: Similar to histogram with quantiles
 * 
 * Prometheus Format:
 * # HELP kuzu_queries_total Total number of queries executed
 * # TYPE kuzu_queries_total counter
 * kuzu_queries_total{status="success"} 12345
 * kuzu_queries_total{status="error"} 67
 */

#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <atomic>
#include <chrono>
#include <sstream>
#include <iomanip>
#include <cmath>

namespace kuzu {
namespace extension {
namespace metrics {

/**
 * Metric label (key-value pair)
 */
struct Label {
    std::string name;
    std::string value;
};

/**
 * Histogram bucket configuration
 */
struct HistogramBuckets {
    static std::vector<double> defaultLatencyBuckets() {
        return {0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0};
    }
    
    static std::vector<double> defaultSizeBuckets() {
        return {100, 500, 1000, 5000, 10000, 50000, 100000, 500000, 1000000};
    }
};

/**
 * Counter metric (monotonically increasing)
 */
class Counter {
public:
    Counter(const std::string& name, const std::string& help)
        : name_(name), help_(help), value_(0) {}
    
    void inc(double amount = 1.0) {
        std::lock_guard<std::mutex> lock(mutex_);
        value_ += amount;
    }
    
    double get() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return value_;
    }
    
    std::string serialize(const std::vector<Label>& labels = {}) const {
        std::ostringstream ss;
        ss << "# HELP " << name_ << " " << help_ << "\n";
        ss << "# TYPE " << name_ << " counter\n";
        ss << name_ << formatLabels(labels) << " " << std::fixed << std::setprecision(6) << get() << "\n";
        return ss.str();
    }
    
    const std::string& getName() const { return name_; }

private:
    std::string name_;
    std::string help_;
    mutable std::mutex mutex_;
    double value_;
    
    std::string formatLabels(const std::vector<Label>& labels) const {
        if (labels.empty()) return "";
        std::ostringstream ss;
        ss << "{";
        for (size_t i = 0; i < labels.size(); i++) {
            if (i > 0) ss << ",";
            ss << labels[i].name << "=\"" << labels[i].value << "\"";
        }
        ss << "}";
        return ss.str();
    }
};

/**
 * Gauge metric (point-in-time value)
 */
class Gauge {
public:
    Gauge(const std::string& name, const std::string& help)
        : name_(name), help_(help), value_(0) {}
    
    void set(double value) {
        std::lock_guard<std::mutex> lock(mutex_);
        value_ = value;
    }
    
    void inc(double amount = 1.0) {
        std::lock_guard<std::mutex> lock(mutex_);
        value_ += amount;
    }
    
    void dec(double amount = 1.0) {
        std::lock_guard<std::mutex> lock(mutex_);
        value_ -= amount;
    }
    
    double get() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return value_;
    }
    
    std::string serialize(const std::vector<Label>& labels = {}) const {
        std::ostringstream ss;
        ss << "# HELP " << name_ << " " << help_ << "\n";
        ss << "# TYPE " << name_ << " gauge\n";
        ss << name_ << formatLabels(labels) << " " << std::fixed << std::setprecision(6) << get() << "\n";
        return ss.str();
    }

private:
    std::string name_;
    std::string help_;
    mutable std::mutex mutex_;
    double value_;
    
    std::string formatLabels(const std::vector<Label>& labels) const {
        if (labels.empty()) return "";
        std::ostringstream ss;
        ss << "{";
        for (size_t i = 0; i < labels.size(); i++) {
            if (i > 0) ss << ",";
            ss << labels[i].name << "=\"" << labels[i].value << "\"";
        }
        ss << "}";
        return ss.str();
    }
};

/**
 * Histogram metric (distribution of values)
 */
class Histogram {
public:
    Histogram(const std::string& name, const std::string& help,
              const std::vector<double>& buckets = HistogramBuckets::defaultLatencyBuckets())
        : name_(name), help_(help), buckets_(buckets), sum_(0), count_(0) {
        bucketCounts_.resize(buckets_.size(), 0);
    }
    
    void observe(double value) {
        std::lock_guard<std::mutex> lock(mutex_);
        sum_ += value;
        count_++;
        
        for (size_t i = 0; i < buckets_.size(); i++) {
            if (value <= buckets_[i]) {
                bucketCounts_[i]++;
            }
        }
    }
    
    std::string serialize(const std::vector<Label>& labels = {}) const {
        std::lock_guard<std::mutex> lock(mutex_);
        std::ostringstream ss;
        ss << "# HELP " << name_ << " " << help_ << "\n";
        ss << "# TYPE " << name_ << " histogram\n";
        
        std::string labelStr = formatLabels(labels);
        
        // Bucket counts
        uint64_t cumulative = 0;
        for (size_t i = 0; i < buckets_.size(); i++) {
            cumulative += bucketCounts_[i];
            ss << name_ << "_bucket{le=\"" << buckets_[i] << "\"" 
               << (labelStr.empty() ? "" : "," + labelStr.substr(1, labelStr.length()-2))
               << "} " << cumulative << "\n";
        }
        ss << name_ << "_bucket{le=\"+Inf\"" 
           << (labelStr.empty() ? "" : "," + labelStr.substr(1, labelStr.length()-2))
           << "} " << count_ << "\n";
        
        // Sum and count
        ss << name_ << "_sum" << labelStr << " " << std::fixed << std::setprecision(6) << sum_ << "\n";
        ss << name_ << "_count" << labelStr << " " << count_ << "\n";
        
        return ss.str();
    }

private:
    std::string name_;
    std::string help_;
    std::vector<double> buckets_;
    std::vector<uint64_t> bucketCounts_;
    mutable std::mutex mutex_;
    double sum_;
    uint64_t count_;
    
    std::string formatLabels(const std::vector<Label>& labels) const {
        if (labels.empty()) return "";
        std::ostringstream ss;
        ss << "{";
        for (size_t i = 0; i < labels.size(); i++) {
            if (i > 0) ss << ",";
            ss << labels[i].name << "=\"" << labels[i].value << "\"";
        }
        ss << "}";
        return ss.str();
    }
};

/**
 * Kuzu Metrics Registry
 * 
 * Central registry for all Kuzu metrics.
 */
class MetricsRegistry {
public:
    static MetricsRegistry& getInstance() {
        static MetricsRegistry instance;
        return instance;
    }
    
    // Query metrics
    Counter& queriesTotal() { return queriesTotal_; }
    Counter& queryErrorsTotal() { return queryErrorsTotal_; }
    Histogram& queryLatency() { return queryLatency_; }
    
    // Index metrics
    Counter& indexInsertsTotal() { return indexInsertsTotal_; }
    Counter& indexSearchesTotal() { return indexSearchesTotal_; }
    Counter& indexDeletesTotal() { return indexDeletesTotal_; }
    Histogram& indexSearchLatency() { return indexSearchLatency_; }
    
    // Vector metrics
    Counter& embeddingRequestsTotal() { return embeddingRequestsTotal_; }
    Counter& embeddingTokensTotal() { return embeddingTokensTotal_; }
    Histogram& embeddingLatency() { return embeddingLatency_; }
    Histogram& vectorDistanceLatency() { return vectorDistanceLatency_; }
    
    // Connection pool metrics
    Gauge& poolConnectionsTotal() { return poolConnectionsTotal_; }
    Gauge& poolConnectionsIdle() { return poolConnectionsIdle_; }
    Gauge& poolConnectionsInUse() { return poolConnectionsInUse_; }
    Counter& poolAcquisitionsTotal() { return poolAcquisitionsTotal_; }
    Counter& poolTimeoutsTotal() { return poolTimeoutsTotal_; }
    Histogram& poolAcquisitionLatency() { return poolAcquisitionLatency_; }
    
    // Memory metrics
    Gauge& memoryUsedBytes() { return memoryUsedBytes_; }
    Gauge& bufferPoolSizeBytes() { return bufferPoolSizeBytes_; }
    Gauge& bufferPoolHitRatio() { return bufferPoolHitRatio_; }
    
    // Sync metrics
    Counter& syncOperationsTotal() { return syncOperationsTotal_; }
    Counter& syncConflictsTotal() { return syncConflictsTotal_; }
    Histogram& syncLatency() { return syncLatency_; }
    
    /**
     * Export all metrics in Prometheus format
     */
    std::string exportMetrics() const {
        std::ostringstream ss;
        
        // Query metrics
        ss << queriesTotal_.serialize();
        ss << queryErrorsTotal_.serialize();
        ss << queryLatency_.serialize();
        
        // Index metrics
        ss << indexInsertsTotal_.serialize();
        ss << indexSearchesTotal_.serialize();
        ss << indexDeletesTotal_.serialize();
        ss << indexSearchLatency_.serialize();
        
        // Vector metrics
        ss << embeddingRequestsTotal_.serialize();
        ss << embeddingTokensTotal_.serialize();
        ss << embeddingLatency_.serialize();
        ss << vectorDistanceLatency_.serialize();
        
        // Connection pool metrics
        ss << poolConnectionsTotal_.serialize();
        ss << poolConnectionsIdle_.serialize();
        ss << poolConnectionsInUse_.serialize();
        ss << poolAcquisitionsTotal_.serialize();
        ss << poolTimeoutsTotal_.serialize();
        ss << poolAcquisitionLatency_.serialize();
        
        // Memory metrics
        ss << memoryUsedBytes_.serialize();
        ss << bufferPoolSizeBytes_.serialize();
        ss << bufferPoolHitRatio_.serialize();
        
        // Sync metrics
        ss << syncOperationsTotal_.serialize();
        ss << syncConflictsTotal_.serialize();
        ss << syncLatency_.serialize();
        
        return ss.str();
    }

private:
    MetricsRegistry()
        // Query metrics
        : queriesTotal_("kuzu_queries_total", "Total number of queries executed")
        , queryErrorsTotal_("kuzu_query_errors_total", "Total number of query errors")
        , queryLatency_("kuzu_query_latency_seconds", "Query latency in seconds")
        
        // Index metrics
        , indexInsertsTotal_("kuzu_index_inserts_total", "Total index inserts")
        , indexSearchesTotal_("kuzu_index_searches_total", "Total index searches")
        , indexDeletesTotal_("kuzu_index_deletes_total", "Total index deletes")
        , indexSearchLatency_("kuzu_index_search_latency_seconds", "Index search latency")
        
        // Vector metrics
        , embeddingRequestsTotal_("kuzu_embedding_requests_total", "Total embedding API requests")
        , embeddingTokensTotal_("kuzu_embedding_tokens_total", "Total tokens processed")
        , embeddingLatency_("kuzu_embedding_latency_seconds", "Embedding generation latency")
        , vectorDistanceLatency_("kuzu_vector_distance_latency_seconds", "Vector distance calculation latency")
        
        // Connection pool metrics
        , poolConnectionsTotal_("kuzu_pool_connections_total", "Total connections in pool")
        , poolConnectionsIdle_("kuzu_pool_connections_idle", "Idle connections")
        , poolConnectionsInUse_("kuzu_pool_connections_in_use", "Connections in use")
        , poolAcquisitionsTotal_("kuzu_pool_acquisitions_total", "Total connection acquisitions")
        , poolTimeoutsTotal_("kuzu_pool_timeouts_total", "Connection acquisition timeouts")
        , poolAcquisitionLatency_("kuzu_pool_acquisition_latency_seconds", "Connection acquisition latency")
        
        // Memory metrics
        , memoryUsedBytes_("kuzu_memory_used_bytes", "Memory used in bytes")
        , bufferPoolSizeBytes_("kuzu_buffer_pool_size_bytes", "Buffer pool size")
        , bufferPoolHitRatio_("kuzu_buffer_pool_hit_ratio", "Buffer pool hit ratio")
        
        // Sync metrics
        , syncOperationsTotal_("kuzu_sync_operations_total", "Total sync operations")
        , syncConflictsTotal_("kuzu_sync_conflicts_total", "Sync conflicts")
        , syncLatency_("kuzu_sync_latency_seconds", "Sync operation latency")
    {}
    
    // Query metrics
    Counter queriesTotal_;
    Counter queryErrorsTotal_;
    Histogram queryLatency_;
    
    // Index metrics
    Counter indexInsertsTotal_;
    Counter indexSearchesTotal_;
    Counter indexDeletesTotal_;
    Histogram indexSearchLatency_;
    
    // Vector metrics
    Counter embeddingRequestsTotal_;
    Counter embeddingTokensTotal_;
    Histogram embeddingLatency_;
    Histogram vectorDistanceLatency_;
    
    // Connection pool metrics
    Gauge poolConnectionsTotal_;
    Gauge poolConnectionsIdle_;
    Gauge poolConnectionsInUse_;
    Counter poolAcquisitionsTotal_;
    Counter poolTimeoutsTotal_;
    Histogram poolAcquisitionLatency_;
    
    // Memory metrics
    Gauge memoryUsedBytes_;
    Gauge bufferPoolSizeBytes_;
    Gauge bufferPoolHitRatio_;
    
    // Sync metrics
    Counter syncOperationsTotal_;
    Counter syncConflictsTotal_;
    Histogram syncLatency_;
};

/**
 * RAII timer for histogram observation
 */
class ScopedTimer {
public:
    ScopedTimer(Histogram& histogram)
        : histogram_(histogram), start_(std::chrono::steady_clock::now()) {}
    
    ~ScopedTimer() {
        auto end = std::chrono::steady_clock::now();
        double seconds = std::chrono::duration<double>(end - start_).count();
        histogram_.observe(seconds);
    }

private:
    Histogram& histogram_;
    std::chrono::steady_clock::time_point start_;
};

} // namespace metrics
} // namespace extension
} // namespace kuzu

/**
 * Usage Example:
 * 
 * auto& metrics = MetricsRegistry::getInstance();
 * 
 * // Record query
 * {
 *     ScopedTimer timer(metrics.queryLatency());
 *     executeQuery(...);
 * }
 * metrics.queriesTotal().inc();
 * 
 * // Record vector search
 * {
 *     ScopedTimer timer(metrics.indexSearchLatency());
 *     vectorIndex.search(query, k);
 * }
 * metrics.indexSearchesTotal().inc();
 * 
 * // Update connection pool stats
 * metrics.poolConnectionsTotal().set(pool.getStats().totalConnections);
 * metrics.poolConnectionsIdle().set(pool.getStats().idleConnections);
 * 
 * // Export for Prometheus scraping
 * std::string output = metrics.exportMetrics();
 * 
 * Example Output:
 * # HELP kuzu_queries_total Total number of queries executed
 * # TYPE kuzu_queries_total counter
 * kuzu_queries_total 12345.000000
 * # HELP kuzu_query_latency_seconds Query latency in seconds
 * # TYPE kuzu_query_latency_seconds histogram
 * kuzu_query_latency_seconds_bucket{le="0.001"} 100
 * kuzu_query_latency_seconds_bucket{le="0.01"} 500
 * ...
 * kuzu_query_latency_seconds_sum 45.678
 * kuzu_query_latency_seconds_count 12345
 */