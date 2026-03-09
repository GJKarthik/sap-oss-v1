# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
HippoCPP Buffer Manager Module for Mojo

Provides buffer pool management for caching database pages in memory.
Implements page pinning, eviction policies, and dirty page tracking.
"""

from memory import memset, memcpy
from sys import sizeof


# Constants
alias PAGE_SIZE: Int = 4096
alias INVALID_FRAME_IDX: Int = -1


@value
struct BufferFrame:
    """
    Buffer frame - holds a cached page in memory.

    Tracks pin count, dirty flag, page index, and access statistics
    for eviction policy decisions.
    """
    var page_idx: Int
    var pin_count: Int
    var dirty: Bool
    var access_count: Int
    var buffer: DTypePointer[DType.uint8]

    fn __init__(inout self, page_idx: Int = -1):
        self.page_idx = page_idx
        self.pin_count = 0
        self.dirty = False
        self.access_count = 0
        self.buffer = DTypePointer[DType.uint8].alloc(PAGE_SIZE)
        memset(self.buffer, 0, PAGE_SIZE)

    fn pin(inout self):
        """Increment pin count."""
        self.pin_count += 1
        self.access_count += 1

    fn unpin(inout self):
        """Decrement pin count."""
        if self.pin_count > 0:
            self.pin_count -= 1

    fn is_pinned(self) -> Bool:
        return self.pin_count > 0

    fn mark_dirty(inout self):
        self.dirty = True

    fn clear_dirty(inout self):
        self.dirty = False

    fn free_buffer(inout self):
        """Free the underlying buffer memory."""
        self.buffer.free()


struct BufferManager:
    """
    Buffer manager - manages a pool of frames for caching pages.

    Implements pin/unpin operations, dirty page tracking, and
    clock algorithm for page eviction.
    """
    var frames: List[BufferFrame]
    var num_frames: Int
    var clock_hand: Int

    fn __init__(inout self, num_frames: Int):
        self.frames = List[BufferFrame]()
        self.num_frames = num_frames
        self.clock_hand = 0
        for i in range(num_frames):
            self.frames.append(BufferFrame(INVALID_FRAME_IDX))

    fn pin_frame(inout self, frame_idx: Int) -> DTypePointer[DType.uint8]:
        """Pin a frame and return its buffer pointer."""
        if frame_idx >= 0 and frame_idx < self.num_frames:
            self.frames[frame_idx].pin()
            return self.frames[frame_idx].buffer
        return DTypePointer[DType.uint8]()

    fn unpin_frame(inout self, frame_idx: Int):
        """Unpin a frame, allowing it to be evicted."""
        if frame_idx >= 0 and frame_idx < self.num_frames:
            self.frames[frame_idx].unpin()

    fn mark_dirty(inout self, frame_idx: Int):
        """Mark a frame as dirty."""
        if frame_idx >= 0 and frame_idx < self.num_frames:
            self.frames[frame_idx].mark_dirty()

    fn flush(inout self, frame_idx: Int):
        """Flush a dirty frame (clear dirty flag)."""
        if frame_idx >= 0 and frame_idx < self.num_frames:
            self.frames[frame_idx].clear_dirty()

    fn evict_frame(inout self) -> Int:
        """Evict a frame using clock algorithm. Returns frame index or -1."""
        var attempts = 0
        while attempts < self.num_frames * 2:
            var idx = self.clock_hand
            self.clock_hand = (self.clock_hand + 1) % self.num_frames
            if not self.frames[idx].is_pinned():
                if self.frames[idx].access_count == 0:
                    return idx
                else:
                    self.frames[idx].access_count -= 1
            attempts += 1
        return INVALID_FRAME_IDX

    fn is_frame_dirty(self, frame_idx: Int) -> Bool:
        """Check if a frame is dirty."""
        if frame_idx >= 0 and frame_idx < self.num_frames:
            return self.frames[frame_idx].dirty
        return False

    fn get_stats(self) -> (Int, Int, Int):
        """Get stats: (total_frames, pinned_count, dirty_count)."""
        var pinned = 0
        var dirty = 0
        for i in range(self.num_frames):
            if self.frames[i].is_pinned():
                pinned += 1
            if self.frames[i].dirty:
                dirty += 1
        return (self.num_frames, pinned, dirty)

    fn close(inout self):
        """Release all frame buffers."""
        for i in range(self.num_frames):
            self.frames[i].free_buffer()


# ============================================================================
# Tests
# ============================================================================

fn test_buffer_frame():
    """Test BufferFrame operations."""
    var frame = BufferFrame(42)
    assert_equal(frame.page_idx, 42)
    assert_true(not frame.is_pinned())

    frame.pin()
    assert_true(frame.is_pinned())
    assert_equal(frame.pin_count, 1)

    frame.unpin()
    assert_true(not frame.is_pinned())

    frame.mark_dirty()
    assert_true(frame.dirty)
    frame.clear_dirty()
    assert_true(not frame.dirty)
    frame.free_buffer()
    print("✓ BufferFrame tests passed")


fn test_buffer_manager():
    """Test BufferManager operations."""
    var bm = BufferManager(4)

    # Test pin/unpin
    var buf = bm.pin_frame(0)
    bm.mark_dirty(0)
    assert_true(bm.is_frame_dirty(0))

    bm.flush(0)
    assert_true(not bm.is_frame_dirty(0))
    bm.unpin_frame(0)

    # Test eviction
    var evicted = bm.evict_frame()
    assert_true(evicted >= 0)

    # Test stats
    var stats = bm.get_stats()
    assert_equal(stats.get[0, Int](), 4)

    bm.close()
    print("✓ BufferManager tests passed")


fn main():
    """Run all tests."""
    print("Running Mojo buffer_manager module tests...")
    test_buffer_frame()
    test_buffer_manager()
    print("All tests passed! ✓")

