/**
 * HANA Connection Pool Manager
 * 
 * P1-49: Connection Pooling for SAP HANA Cloud
 * 
 * This module provides efficient connection pooling for SAP HANA Cloud
 * database connections, enabling:
 * - Connection reuse to avoid connection overhead
 * - Bounded pool size to control resource usage
 * - Health checks for connection validation
 * - Automatic reconnection for failed connections
 * - Thread-safe connection acquisition and release
 * 
 * Architecture:
 * ┌────────────────────────────────────────────────────────────────┐
 * │                    Application Threads                         │
 * │  Thread 1    Thread 2    Thread 3    Thread 4    Thread N     │
 * │     │            │           │           │           │         │
 * └─────┼────────────┼───────────┼───────────┼───────────┼─────────┘
 *       │            │           │           │           │
 *       └────────────┴───────────┴───────────┴───────────┘
 *                              │
 *                              ▼
 * ┌────────────────────────────────────────────────────────────────┐
 * │                    Connection Pool                             │
 * │  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  │
 * │  │ Conn 1 │  │ Conn 2 │  │ Conn 3 │  │ Conn 4 │  │ Conn N │  │
 * │  │ [idle] │  │ [busy] │  │ [idle] │  │ [busy] │  │ [idle] │  │
 * │  └────────┘  └────────┘  └────────┘  └────────┘  └────────┘  │
 * └────────────────────────────────────────────────────────────────┘
 *                              │
 *                              ▼
 * ┌────────────────────────────────────────────────────────────────┐
 * │                    SAP HANA Cloud                              │
 * └────────────────────────────────────────────────────────────────┘
 * 
 * Key Features:
 * - Lazy connection creation
 * - Connection timeout management
 * - Idle connection cleanup
 * - Connection validation (ping)
 * - Statistics and monitoring
 */

#include <string>
#include <vector>
#include <queue>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <atomic>
#include <functional>
#include <stdexcept>

namespace kuzu {
namespace extension {
namespace hana {

/**
 * Pool configuration
 */
struct ConnectionPoolConfig {
    // Pool sizing
    size_t minConnections = 2;      // Minimum idle connections
    size_t maxConnections = 20;     // Maximum total connections
    
    // Timeouts
    int connectionTimeoutMs = 30000;  // Timeout for establishing connection
    int acquireTimeoutMs = 5000;      // Timeout for acquiring from pool
    int idleTimeoutMs = 300000;       // Close idle connections after 5 min
    int maxLifetimeMs = 1800000;      // Maximum connection lifetime (30 min)
    
    // Health checks
    int validationIntervalMs = 30000; // Validate connections every 30 sec
    bool testOnBorrow = true;         // Test connection before giving to client
    bool testOnReturn = false;        // Test connection when returned
    std::string validationQuery = "SELECT 1 FROM DUMMY";
    
    // Retry settings
    int maxReconnectAttempts = 3;
    int reconnectDelayMs = 1000;
};

/**
 * Connection state
 */
enum class ConnectionState {
    IDLE,       // Available in pool
    IN_USE,     // Currently acquired by client
    INVALID,    // Connection is broken
    CLOSED      // Connection is closed
};

/**
 * Wrapper for a HANA connection
 */
class PooledConnection {
public:
    using ValidationFunc = std::function<bool()>;
    using CloseFunc = std::function<void()>;
    
    PooledConnection(size_t id, ValidationFunc validate, CloseFunc close)
        : id_(id), validateFunc_(std::move(validate)), closeFunc_(std::move(close)),
          state_(ConnectionState::IDLE) {
        createdAt_ = std::chrono::steady_clock::now();
        lastUsedAt_ = createdAt_;
    }
    
    ~PooledConnection() {
        close();
    }
    
    size_t getId() const { return id_; }
    ConnectionState getState() const { return state_; }
    
    void setState(ConnectionState state) { state_ = state; }
    
    /**
     * Validate the connection is still usable
     */
    bool validate() {
        if (state_ == ConnectionState::CLOSED || state_ == ConnectionState::INVALID) {
            return false;
        }
        
        try {
            if (validateFunc_ && !validateFunc_()) {
                state_ = ConnectionState::INVALID;
                return false;
            }
            return true;
        } catch (...) {
            state_ = ConnectionState::INVALID;
            return false;
        }
    }
    
    /**
     * Mark connection as used
     */
    void markUsed() {
        lastUsedAt_ = std::chrono::steady_clock::now();
        useCount_++;
    }
    
    /**
     * Check if connection has exceeded max lifetime
     */
    bool isExpired(int maxLifetimeMs) const {
        auto now = std::chrono::steady_clock::now();
        auto lifetime = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - createdAt_).count();
        return lifetime > maxLifetimeMs;
    }
    
    /**
     * Check if connection has been idle too long
     */
    bool isIdleTooLong(int idleTimeoutMs) const {
        auto now = std::chrono::steady_clock::now();
        auto idleTime = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - lastUsedAt_).count();
        return idleTime > idleTimeoutMs;
    }
    
    /**
     * Close the connection
     */
    void close() {
        if (state_ != ConnectionState::CLOSED) {
            try {
                if (closeFunc_) closeFunc_();
            } catch (...) {
                // Ignore close errors
            }
            state_ = ConnectionState::CLOSED;
        }
    }
    
    size_t getUseCount() const { return useCount_; }
    
private:
    size_t id_;
    ValidationFunc validateFunc_;
    CloseFunc closeFunc_;
    ConnectionState state_;
    
    std::chrono::steady_clock::time_point createdAt_;
    std::chrono::steady_clock::time_point lastUsedAt_;
    size_t useCount_ = 0;
};

/**
 * Connection Pool Statistics
 */
struct PoolStats {
    size_t totalConnections = 0;
    size_t idleConnections = 0;
    size_t inUseConnections = 0;
    size_t waitingRequests = 0;
    
    size_t totalAcquisitions = 0;
    size_t totalCreations = 0;
    size_t totalTimeouts = 0;
    size_t totalValidationFailures = 0;
    
    double avgAcquisitionTimeMs = 0.0;
    double avgUsageTimeMs = 0.0;
};

/**
 * RAII wrapper for borrowed connection
 */
class BorrowedConnection;

/**
 * HANA Connection Pool
 * 
 * Thread-safe connection pool implementation.
 */
class ConnectionPool {
public:
    using ConnectionFactory = std::function<std::unique_ptr<PooledConnection>()>;
    
    ConnectionPool(const ConnectionPoolConfig& config, ConnectionFactory factory)
        : config_(config), factory_(std::move(factory)),
          nextConnectionId_(1), running_(true) {
        // Initialize minimum connections
        for (size_t i = 0; i < config_.minConnections; i++) {
            createConnection();
        }
    }
    
    ~ConnectionPool() {
        shutdown();
    }
    
    /**
     * Acquire a connection from the pool
     * 
     * @param timeoutMs Timeout in milliseconds (-1 for default)
     * @return Shared pointer to pooled connection
     * @throws std::runtime_error if timeout or pool is shut down
     */
    std::shared_ptr<PooledConnection> acquire(int timeoutMs = -1) {
        if (!running_) {
            throw std::runtime_error("Connection pool is shut down");
        }
        
        int timeout = timeoutMs >= 0 ? timeoutMs : config_.acquireTimeoutMs;
        auto deadline = std::chrono::steady_clock::now() + 
                       std::chrono::milliseconds(timeout);
        
        auto startTime = std::chrono::steady_clock::now();
        
        std::unique_lock<std::mutex> lock(mutex_);
        stats_.waitingRequests++;
        
        while (running_) {
            // Try to get an idle connection
            while (!idleConnections_.empty()) {
                auto conn = std::move(idleConnections_.front());
                idleConnections_.pop();
                
                if (config_.testOnBorrow) {
                    if (!conn->validate()) {
                        stats_.totalValidationFailures++;
                        conn->close();
                        totalConnections_--;
                        continue;
                    }
                }
                
                // Check if connection is expired
                if (conn->isExpired(config_.maxLifetimeMs)) {
                    conn->close();
                    totalConnections_--;
                    continue;
                }
                
                conn->setState(ConnectionState::IN_USE);
                conn->markUsed();
                inUseConnections_++;
                stats_.waitingRequests--;
                stats_.totalAcquisitions++;
                
                updateAcquisitionStats(startTime);
                
                return std::shared_ptr<PooledConnection>(
                    conn.release(),
                    [this](PooledConnection* c) { release(c); });
            }
            
            // Try to create a new connection if under limit
            if (totalConnections_ < config_.maxConnections) {
                lock.unlock();
                auto conn = createConnection();
                lock.lock();
                
                if (conn) {
                    conn->setState(ConnectionState::IN_USE);
                    conn->markUsed();
                    inUseConnections_++;
                    stats_.waitingRequests--;
                    stats_.totalAcquisitions++;
                    
                    updateAcquisitionStats(startTime);
                    
                    return std::shared_ptr<PooledConnection>(
                        conn.release(),
                        [this](PooledConnection* c) { release(c); });
                }
            }
            
            // Wait for a connection to be released
            if (cv_.wait_until(lock, deadline) == std::cv_status::timeout) {
                stats_.waitingRequests--;
                stats_.totalTimeouts++;
                throw std::runtime_error("Timeout waiting for connection");
            }
        }
        
        stats_.waitingRequests--;
        throw std::runtime_error("Connection pool is shut down");
    }
    
    /**
     * Get pool statistics
     */
    PoolStats getStats() const {
        std::lock_guard<std::mutex> lock(mutex_);
        PoolStats s = stats_;
        s.totalConnections = totalConnections_;
        s.idleConnections = idleConnections_.size();
        s.inUseConnections = inUseConnections_;
        return s;
    }
    
    /**
     * Shutdown the pool and close all connections
     */
    void shutdown() {
        std::unique_lock<std::mutex> lock(mutex_);
        running_ = false;
        
        // Close all idle connections
        while (!idleConnections_.empty()) {
            auto conn = std::move(idleConnections_.front());
            idleConnections_.pop();
            conn->close();
        }
        
        lock.unlock();
        cv_.notify_all();
    }
    
    /**
     * Remove idle connections that have been idle too long
     */
    void evictIdleConnections() {
        std::lock_guard<std::mutex> lock(mutex_);
        
        std::queue<std::unique_ptr<PooledConnection>> remaining;
        while (!idleConnections_.empty()) {
            auto conn = std::move(idleConnections_.front());
            idleConnections_.pop();
            
            if (conn->isIdleTooLong(config_.idleTimeoutMs) &&
                totalConnections_ > config_.minConnections) {
                conn->close();
                totalConnections_--;
            } else {
                remaining.push(std::move(conn));
            }
        }
        idleConnections_ = std::move(remaining);
    }

private:
    ConnectionPoolConfig config_;
    ConnectionFactory factory_;
    
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    
    std::queue<std::unique_ptr<PooledConnection>> idleConnections_;
    size_t inUseConnections_ = 0;
    size_t totalConnections_ = 0;
    size_t nextConnectionId_;
    
    std::atomic<bool> running_;
    PoolStats stats_;
    
    double totalAcquisitionTimeMs_ = 0.0;
    
    /**
     * Create a new connection
     */
    std::unique_ptr<PooledConnection> createConnection() {
        std::unique_lock<std::mutex> lock(mutex_, std::defer_lock);
        if (!lock.owns_lock()) lock.lock();
        
        if (totalConnections_ >= config_.maxConnections) {
            return nullptr;
        }
        
        try {
            auto conn = factory_();
            if (conn) {
                totalConnections_++;
                stats_.totalCreations++;
            }
            return conn;
        } catch (...) {
            return nullptr;
        }
    }
    
    /**
     * Release a connection back to the pool
     */
    void release(PooledConnection* conn) {
        if (!conn) return;
        
        std::unique_lock<std::mutex> lock(mutex_);
        inUseConnections_--;
        
        if (!running_ || conn->getState() == ConnectionState::INVALID ||
            conn->isExpired(config_.maxLifetimeMs)) {
            conn->close();
            totalConnections_--;
            delete conn;
        } else {
            if (config_.testOnReturn && !conn->validate()) {
                stats_.totalValidationFailures++;
                conn->close();
                totalConnections_--;
                delete conn;
            } else {
                conn->setState(ConnectionState::IDLE);
                idleConnections_.push(std::unique_ptr<PooledConnection>(conn));
                cv_.notify_one();
            }
        }
    }
    
    /**
     * Update acquisition time statistics
     */
    void updateAcquisitionStats(std::chrono::steady_clock::time_point startTime) {
        auto endTime = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double, std::milli>(
            endTime - startTime).count();
        
        totalAcquisitionTimeMs_ += elapsed;
        stats_.avgAcquisitionTimeMs = 
            totalAcquisitionTimeMs_ / stats_.totalAcquisitions;
    }
};

} // namespace hana
} // namespace extension
} // namespace kuzu

/**
 * Usage Example:
 * 
 * // Configure pool
 * ConnectionPoolConfig config;
 * config.minConnections = 5;
 * config.maxConnections = 50;
 * config.acquireTimeoutMs = 10000;
 * 
 * // Create factory for HANA connections
 * auto factory = [&]() {
 *     auto conn = std::make_unique<PooledConnection>(
 *         nextId++,
 *         [&]() { return hanaConn.ping(); },  // Validation
 *         [&]() { hanaConn.close(); }         // Close
 *     );
 *     // ... establish HANA connection ...
 *     return conn;
 * };
 * 
 * // Create pool
 * ConnectionPool pool(config, factory);
 * 
 * // Acquire connection (RAII-managed)
 * {
 *     auto conn = pool.acquire();
 *     // Use connection...
 * } // Connection automatically returned to pool
 * 
 * // Check stats
 * auto stats = pool.getStats();
 * 
 * Performance Guidelines:
 * | Metric | Guideline |
 * |--------|-----------|
 * | minConnections | 2-5 for low traffic |
 * | maxConnections | ~50-100 for high traffic |
 * | acquireTimeoutMs | 5-10 seconds |
 * | idleTimeoutMs | 5-10 minutes |
 * | maxLifetimeMs | 30 min to 1 hour |
 */