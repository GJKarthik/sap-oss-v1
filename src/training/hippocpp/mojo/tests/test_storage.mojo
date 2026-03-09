# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Tests for the HippoCPP Storage Module."""

from memory import memset, memcpy


alias PAGE_SIZE: Int = 4096


fn test_page_idx():
    """Test PageIdx type."""
    from hippocpp.storage import PageIdx, INVALID_PAGE_IDX

    let valid = PageIdx(0)
    assert_true(valid.is_valid())

    let also_valid = PageIdx(100)
    assert_true(also_valid.is_valid())
    assert_true(valid != also_valid)
    print("✓ PageIdx tests passed")


fn test_table_id():
    """Test TableId type."""
    from hippocpp.storage import TableId

    let tid = TableId(5)
    assert_true(tid.is_valid())
    assert_equal(tid.value, 5)
    print("✓ TableId tests passed")


fn test_internal_id():
    """Test InternalId type."""
    from hippocpp.storage import InternalId, TableId

    let iid = InternalId(TableId(1), 42)
    assert_true(iid.is_valid())
    assert_equal(iid.offset, 42)
    print("✓ InternalId tests passed")


fn test_file_handle_in_memory():
    """Test in-memory FileHandle."""
    from hippocpp.storage import FileHandle, PageIdx

    var fh = FileHandle.create_in_memory()
    assert_true(fh.is_in_memory)
    assert_equal(fh.get_num_pages(), 0)

    # Extend and write
    fh.extend(2)
    assert_equal(fh.get_num_pages(), 2)

    # Write data to page 0
    var write_buf = DTypePointer[DType.uint8].alloc(PAGE_SIZE)
    write_buf.store(0, UInt8(0xAB))
    write_buf.store(1, UInt8(0xCD))
    fh.write_page(PageIdx(0), write_buf)

    # Read it back
    var read_buf = DTypePointer[DType.uint8].alloc(PAGE_SIZE)
    fh.read_page(PageIdx(0), read_buf)
    assert_equal(read_buf.load(0), UInt8(0xAB))
    assert_equal(read_buf.load(1), UInt8(0xCD))

    write_buf.free()
    read_buf.free()
    fh.close()
    assert_equal(fh.get_num_pages(), 0)
    print("✓ FileHandle in-memory tests passed")


fn test_page_manager():
    """Test PageManager allocation and freeing."""
    from hippocpp.storage import PageManager, FileHandle, PageIdx

    var fh = FileHandle.create_in_memory()
    var pm = PageManager(fh^)

    let p0 = pm.allocate_page()
    assert_true(p0.is_valid())

    let p1 = pm.allocate_page()
    assert_true(p1.is_valid())
    assert_true(p0 != p1)

    # Free and re-allocate
    pm.free_page(p0)
    pm.finalize_checkpoint()

    let p2 = pm.allocate_page()
    assert_true(p2 == p0)  # should reuse freed page

    let stats = pm.get_stats()
    assert_true(stats.get[0, Int]() >= 2)  # total pages
    print("✓ PageManager tests passed")


fn test_database_header():
    """Test DatabaseHeader."""
    from hippocpp.storage import DatabaseHeader, KUZU_MAGIC

    var header = DatabaseHeader()
    assert_true(header.is_valid())
    assert_equal(header.magic, KUZU_MAGIC)

    header.increment_checkpoint()
    assert_equal(header.checkpoint_id, 1)

    let tid = header.allocate_table_id()
    assert_equal(tid.value, 0)
    let tid2 = header.allocate_table_id()
    assert_equal(tid2.value, 1)
    print("✓ DatabaseHeader tests passed")


fn test_storage_manager():
    """Test StorageManager lifecycle."""
    from hippocpp.storage import StorageManager

    var sm = StorageManager("test_db", in_memory=True)
    sm.initialize()

    assert_true(sm.initialized)
    assert_true(sm.checkpoint())

    sm.close()
    assert_true(not sm.initialized)
    print("✓ StorageManager tests passed")


fn test_simd_copy():
    """Test SIMD page copy."""
    from hippocpp.storage import simd_copy_page

    var src = DTypePointer[DType.uint8].alloc(PAGE_SIZE)
    var dst = DTypePointer[DType.uint8].alloc(PAGE_SIZE)

    # Fill source with pattern
    for i in range(PAGE_SIZE):
        src.store(i, UInt8(i % 256))
    memset(dst, 0, PAGE_SIZE)

    simd_copy_page[16](src, dst)

    # Verify copy
    for i in range(PAGE_SIZE):
        assert_equal(src.load(i), dst.load(i))

    src.free()
    dst.free()
    print("✓ SIMD copy tests passed")


fn main():
    """Run all storage tests."""
    print("Running storage module tests...")
    test_page_idx()
    test_table_id()
    test_internal_id()
    test_file_handle_in_memory()
    test_page_manager()
    test_database_header()
    test_storage_manager()
    test_simd_copy()
    print("All storage tests passed! ✓")

