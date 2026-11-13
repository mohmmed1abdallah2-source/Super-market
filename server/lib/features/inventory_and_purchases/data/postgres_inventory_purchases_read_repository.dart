import 'package:postgres/postgres.dart';

/// Branch-scoped read repository for inventory and purchasing projections.
///
/// Writes are intentionally added only with their transactional use cases;
/// this class never accepts a branch ID from a JSON body.
final class PostgresInventoryPurchasesReadRepository {
  PostgresInventoryPurchasesReadRepository(this._connection);

  final PostgreSQLConnection _connection;

  Future<List<Map<String, Object?>>> listWarehouses({
    required String branchId,
  }) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT id::text AS id, code, name_ar AS name,
                warehouse_type AS "warehouseType",
                is_sellable AS "isSellable", is_active AS "isActive"
         FROM warehouses
         WHERE branch_id = @branch AND is_active = TRUE
         ORDER BY code, id''',
      substitutionValues: {'branch': branchId},
    );
    return rows.map(_flatten).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> listLocations({
    required String branchId,
    String? warehouseId,
  }) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT id::text AS id, warehouse_id AS "warehouseId", code,
                name_ar AS name, location_type AS "locationType",
                is_active AS "isActive"
         FROM aisle_shelf_locations
         WHERE branch_id = @branch
           AND is_active = TRUE
           AND (@warehouse::text IS NULL OR warehouse_id = @warehouse)
         ORDER BY warehouse_id, code, id''',
      substitutionValues: {
        'branch': branchId,
        'warehouse': warehouseId,
      },
    );
    return rows.map(_flatten).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> listBatches({
    required String branchId,
    String? productId,
    String? warehouseId,
    bool includeInactive = false,
  }) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT id::text AS id, product_id AS "productId",
                warehouse_id AS "warehouseId", location_id AS "locationId",
                batch_no AS "batchNo", expiry_date::text AS "expiryDate",
                pack_conversion_factor::text AS "packConversionFactor",
                sealed_cartons AS "sealedCartons",
                loose_base_qty::text AS "looseBaseQty",
                total_base_qty::text AS "totalBaseQty",
                unit_cost_base::text AS "unitCostBase", status
         FROM product_batches_fefo
         WHERE branch_id = @branch
           AND (@product::text IS NULL OR product_id = @product)
           AND (@warehouse::text IS NULL OR warehouse_id = @warehouse)
           AND (@includeInactive::boolean OR status = 'ACTIVE')
         ORDER BY expiry_date, created_at, id''',
      substitutionValues: {
        'branch': branchId,
        'product': productId,
        'warehouse': warehouseId,
        'includeInactive': includeInactive,
      },
    );
    return rows.map(_flatten).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> listMovements({
    required String branchId,
    String? productId,
    String? warehouseId,
    DateTime? from,
    DateTime? to,
  }) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT id::text AS id, product_id AS "productId",
                warehouse_id AS "warehouseId",
                product_batch_id AS "productBatchId",
                movement_type AS "movementType",
                movement_date::text AS "movementDate",
                quantity_base::text AS "quantityBase",
                unit_cost_base::text AS "unitCostBase",
                doc_type AS "documentType", doc_id AS "documentId",
                reference_no AS "referenceNo", notes
         FROM stock_movements
         WHERE branch_id = @branch
           AND (@product::text IS NULL OR product_id = @product)
           AND (@warehouse::text IS NULL OR warehouse_id = @warehouse)
           AND (@from::timestamptz IS NULL OR movement_date >= @from)
           AND (@to::timestamptz IS NULL OR movement_date <= @to)
         ORDER BY movement_date DESC, id DESC
         LIMIT 500''',
      substitutionValues: {
        'branch': branchId,
        'product': productId,
        'warehouse': warehouseId,
        'from': from?.toUtc(),
        'to': to?.toUtc(),
      },
    );
    return rows.map(_flatten).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> listStocktakingSessions({
    required String branchId,
  }) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT id::text AS id, warehouse_id AS "warehouseId",
                session_no AS "sessionNo", status, blind_count AS "blindCount",
                started_at::text AS "startedAt",
                completed_at::text AS "completedAt",
                approved_at::text AS "approvedAt"
         FROM stocktaking_sessions
         WHERE branch_id = @branch
         ORDER BY started_at DESC, id DESC
         LIMIT 200''',
      substitutionValues: {'branch': branchId},
    );
    return rows.map(_flatten).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> listShortageSuggestions({
    required String branchId,
  }) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT id::text AS "productId", name_ar AS "productName",
                stock_base_qty::text AS "currentBaseQty",
                min_stock_alert_qty::text AS "minimumBaseQty",
                GREATEST(min_stock_alert_qty - stock_base_qty, 0)::numeric(20,6)::text
                  AS "suggestedBaseQty",
                avg_cost_base_unit::text AS "effectiveBaseCost"
         FROM products
         WHERE branch_id = @branch AND is_active = TRUE
           AND min_stock_alert_qty > 0
           AND stock_base_qty < min_stock_alert_qty
         ORDER BY (min_stock_alert_qty - stock_base_qty) DESC, name_ar
         LIMIT 500''',
      substitutionValues: {'branch': branchId},
    );
    return rows.map(_flatten).toList(growable: false);
  }

  Map<String, Object?> _flatten(Map<String, Map<String, Object?>> row) =>
      row.values.fold<Map<String, Object?>>(
        <String, Object?>{},
        (result, values) => result..addAll(values),
      );
}
