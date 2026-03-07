#include <metal_stdlib>
using namespace metal;

// ============================================================================
// GPU-Resident Database (Simple Read-Only Key-Value Store)
// ============================================================================
// Layout: [key_hash: uint64][value_offset: uint32][value_len: uint32]
// Values are stored in a separate buffer.

struct DBEntry {
    ulong key_hash;
    uint value_offset;
    uint value_len;
};

// ============================================================================
// HTTP Request / Response Structs
// ============================================================================
// Simple fixed-size request structure for demo purposes
// In production, this would be a stream or linked list of buffers.

struct HttpRequest {
    device const char* raw_bytes;
    uint length;
};

struct HttpResponse {
    device char* output_buffer;
    atomic_uint* output_length;
    uint max_capacity;
};

// ============================================================================
// Helper Functions
// ============================================================================

// FNV-1a hash function for strings
ulong hash_string(device const char* str, uint len) {
    ulong hash = 0xcbf29ce484222325;
    for (uint i = 0; i < len; i++) {
        hash ^= (ulong)str[i];
        hash *= 0x1099511628211;
    }
    return hash;
}

// Simple memory copy
void my_memcpy(device char* dst, device const char* src, uint len) {
    for (uint i = 0; i < len; i++) {
        dst[i] = src[i];
    }
}

// Compare string with memory
bool str_eq(device const char* a, uint a_len, constant char* b) {
    uint b_len = 0;
    while (b[b_len] != 0) b_len++;
    if (a_len != b_len) return false;
    for (uint i = 0; i < a_len; i++) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// ============================================================================
// The Core Kernel
// ============================================================================

kernel void http_handler(
    device const char* req_buffer [[buffer(0)]],
    device const uint* req_lengths [[buffer(1)]],
    device char* res_buffer [[buffer(2)]],
    device atomic_uint* res_lengths [[buffer(3)]],
    device const DBEntry* db_index [[buffer(4)]],
    device const char* db_values [[buffer(5)]],
    uint num_db_entries [[buffer(6)]],
    uint id [[thread_position_in_grid]]
) {
    // 1. Get request slice
    uint req_len = req_lengths[id];
    if (req_len == 0) return;
    
    // Calculate offset based on fixed stride or prefix sum (simplified: fixed 4KB stride)
    uint req_offset = id * 4096;
    device const char* req = req_buffer + req_offset;

    // 2. Parse Method and Path (Zero-Copy)
    // Find first space (end of Method)
    uint method_len = 0;
    while (method_len < req_len && req[method_len] != ' ') method_len++;

    // Find second space (end of Path)
    uint path_start = method_len + 1;
    uint path_len = 0;
    while (path_start + path_len < req_len && req[path_start + path_len] != ' ') path_len++;

    device const char* path = req + path_start;

    // 3. Database Query (GPU-Side Join)
    // We only query if method is GET and path starts with /db/
    bool found = false;
    uint val_offset = 0;
    uint val_len = 0;

    if (str_eq(req, method_len, "GET") && path_len > 4 && 
        path[0] == '/' && path[1] == 'd' && path[2] == 'b' && path[3] == '/') {
        
        // Extract key from path: /db/<key>
        ulong key_h = hash_string(path + 4, path_len - 4);
        
        // Linear scan (parallelized across threads, one per request)
        // For production: use a hash map or binary search
        for (uint i = 0; i < num_db_entries; i++) {
            if (db_index[i].key_hash == key_h) {
                val_offset = db_index[i].value_offset;
                val_len = db_index[i].value_len;
                found = true;
                break;
            }
        }
    }

    // 4. Construct Response
    // We write to a thread-local output buffer slice (simplified: fixed 8KB stride)
    uint res_offset = id * 8192;
    device char* out = res_buffer + res_offset;
    uint cursor = 0;

    if (found) {
        // HTTP 200 OK
        constant char* header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ";
        uint h_len = 0; while (header[h_len] != 0) h_len++;
        my_memcpy(out + cursor, header, h_len);
        cursor += h_len;

        // Write length (simplified: manual itoa)
        // ... (skipping complex itoa for brevity, assuming small lengths)
        out[cursor++] = '0' + (val_len / 100) % 10;
        out[cursor++] = '0' + (val_len / 10) % 10;
        out[cursor++] = '0' + (val_len % 10);
        
        out[cursor++] = '\r'; out[cursor++] = '\n';
        out[cursor++] = '\r'; out[cursor++] = '\n';

        // Write DB Value
        my_memcpy(out + cursor, db_values + val_offset, val_len);
        cursor += val_len;
    } else {
        // HTTP 404 Not Found
        constant char* msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        uint m_len = 0; while (msg[m_len] != 0) m_len++;
        my_memcpy(out + cursor, msg, m_len);
        cursor += m_len;
    }

    // 5. Commit Output Length
    atomic_store_explicit(&res_lengths[id], cursor, memory_order_relaxed);
}