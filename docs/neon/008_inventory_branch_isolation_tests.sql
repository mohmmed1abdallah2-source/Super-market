-- Iteration 3 / Migration verification 008.
-- Run as one script against a disposable database after migrations 001-004 and 007.
-- All fixture rows are rolled back. Never run with autocommit-per-statement.
BEGIN;

DO $$
DECLARE
  b1 TEXT := 'it3-test-branch-a-' || gen_random_uuid()::text;
  b2 TEXT := 'it3-test-branch-b-' || gen_random_uuid()::text;
  w1 TEXT := 'it3-test-warehouse-a-' || gen_random_uuid()::text;
  w2 TEXT := 'it3-test-warehouse-b-' || gen_random_uuid()::text;
  p1 TEXT := 'it3-test-product-a-' || gen_random_uuid()::text;
  p2 TEXT := 'it3-test-product-b-' || gen_random_uuid()::text;
  w3 TEXT := 'it3-test-warehouse-a2-' || gen_random_uuid()::text;
  batch2 TEXT := 'it3-test-batch-b-' || gen_random_uuid()::text;
  transfer1 TEXT := 'it3-test-transfer-a-' || gen_random_uuid()::text;
  party1 TEXT := 'it3-test-supplier-a-' || gen_random_uuid()::text;
  party2 TEXT := 'it3-test-supplier-b-' || gen_random_uuid()::text;
  po1 TEXT := 'it3-test-po-a-' || gen_random_uuid()::text;
  batch1 TEXT := 'it3-test-batch-a-' || gen_random_uuid()::text;
  movement1 TEXT := 'it3-test-movement-a-' || gen_random_uuid()::text;
  v_count BIGINT;
BEGIN
  INSERT INTO branches(id, code, name_ar)
  VALUES (b1, 'T3A-' || substr(md5(b1),1,8), 'اختبار الدورة الثالثة A'),
         (b2, 'T3B-' || substr(md5(b2),1,8), 'اختبار الدورة الثالثة B');

  INSERT INTO warehouses(id, branch_id, code, name_ar, warehouse_type)
  VALUES (w1, b1, 'WH-A', 'مخزن A', 'BACKROOM'),
         (w2, b2, 'WH-B', 'مخزن B', 'BACKROOM'),
         (w3, b1, 'WH-A2', 'صالة A', 'SALES_FLOOR');

  INSERT INTO products(id, branch_id, sku_code, name_ar, base_unit_name)
  VALUES (p1, b1, 'SKU-' || substr(md5(p1),1,8), 'صنف اختبار A', 'حبة'),
         (p2, b2, 'SKU-' || substr(md5(p2),1,8), 'صنف اختبار B', 'حبة');

  INSERT INTO parties(id, branch_id, party_type, code, name_ar)
  VALUES (party1, b1, 'SUPPLIER', 'SUP-' || substr(md5(party1),1,8), 'مورد A'),
         (party2, b2, 'SUPPLIER', 'SUP-' || substr(md5(party2),1,8), 'مورد B');

  INSERT INTO purchase_orders(id, branch_id, order_no, supplier_party_id)
  VALUES (po1, b1, 'PO-' || substr(md5(po1),1,8), party1);

  -- Same-branch references are accepted.
  INSERT INTO product_batches_fefo(
    id, branch_id, product_id, warehouse_id, batch_no, expiry_date,
    pack_conversion_factor, sealed_cartons, loose_base_qty
  ) VALUES (batch1, b1, p1, w1, 'LOT-OK', CURRENT_DATE + 30, 24, 2, 0);

  INSERT INTO product_batches_fefo(
    id, branch_id, product_id, warehouse_id, batch_no, expiry_date,
    pack_conversion_factor, sealed_cartons, loose_base_qty
  ) VALUES (batch2, b2, p2, w2, 'LOT-B', CURRENT_DATE + 30, 24, 1, 0);

  INSERT INTO stock_transfers(id, branch_id, transfer_no, source_warehouse_id, destination_warehouse_id)
  VALUES (transfer1, b1, 'TR-' || substr(md5(transfer1),1,8), w1, w3);

  INSERT INTO stock_movements(
    id, branch_id, product_id, movement_type, quantity_base, unit_cost_base, doc_type, doc_id, warehouse_id, product_batch_id
  ) VALUES (
    movement1, b1, p1, 'PURCHASE_IN', 48, 1, 'TEST', movement1, w1, batch1
  );

  SELECT COUNT(*) INTO v_count FROM product_batches_fefo
    WHERE id = batch1 AND total_base_qty = 48;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: generated FEFO total quantity';
  END IF;

  -- A branch-A batch cannot reference a branch-B warehouse.
  BEGIN
    INSERT INTO product_batches_fefo(
      id, branch_id, product_id, warehouse_id, batch_no, expiry_date,
      pack_conversion_factor, sealed_cartons, loose_base_qty
    ) VALUES ('cross-' || gen_random_uuid()::text, b1, p1, w2, 'CROSS-WH', CURRENT_DATE + 30, 24, 1, 0);
    RAISE EXCEPTION 'FAIL: cross-branch warehouse reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  -- A branch-A purchase order cannot point to a branch-B supplier.
  BEGIN
    INSERT INTO purchase_orders(id, branch_id, order_no, supplier_party_id)
    VALUES ('cross-po-' || gen_random_uuid()::text, b1, 'CROSS-' || substr(md5(gen_random_uuid()::text),1,8), party2);
    RAISE EXCEPTION 'FAIL: cross-branch supplier reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  -- FEFO balance checks reject negative cartons and negative loose stock.
  BEGIN
    INSERT INTO product_batches_fefo(
      id, branch_id, product_id, warehouse_id, batch_no, expiry_date,
      pack_conversion_factor, sealed_cartons, loose_base_qty
    ) VALUES ('negative-' || gen_random_uuid()::text, b1, p1, w1, 'NEG', CURRENT_DATE + 30, 24, -1, 0);
    RAISE EXCEPTION 'FAIL: negative sealed cartons were accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    UPDATE stock_movements SET notes = 'mutation must fail' WHERE id = movement1;
    RAISE EXCEPTION 'FAIL: stock movement UPDATE was accepted';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;

  BEGIN
    DELETE FROM stock_movements WHERE id = movement1;
    RAISE EXCEPTION 'FAIL: stock movement DELETE was accepted';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;

  -- A branch-A transfer cannot consume a branch-B batch.
  BEGIN
    INSERT INTO stock_transfer_items(id, branch_id, transfer_id, product_batch_id, qty_base)
    VALUES ('cross-item-' || gen_random_uuid()::text, b1, transfer1, batch2, 1);
    RAISE EXCEPTION 'FAIL: invalid transfer item was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  RAISE NOTICE 'PASS: 7 Iteration 3 SQL assertions completed';
END $$;

ROLLBACK;
