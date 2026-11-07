import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'schema_builder.dart';
import 'seed_data.dart';

/// Provides the single configured SQLite database for Android and Windows.
class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();
  static const String _databaseName = 'supermarket_erp.db';
  Database? _database;
  Future<Database>? _opening;

  /// Returns the initialized database, sharing concurrent open requests.
  Future<Database> get database async {
    if (_database != null) return _database!;
    _opening ??= _open();
    try {
      _database = await _opening!;
      return _database!;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _open() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final root = await getDatabasesPath();
    final path = p.join(root, _databaseName);
    return openDatabase(
      path,
      version: SchemaBuilder.version,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.execute('PRAGMA busy_timeout = 5000');
        await db.execute('PRAGMA journal_mode = WAL');
        await db.execute('PRAGMA synchronous = NORMAL');
      },
      onCreate: (db, version) async {
        await SchemaBuilder.createAll(db);
        await SeedData.seed(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 1) {
          await SchemaBuilder.createAll(db);
          await SeedData.seed(db);
        }
      },
    );
  }

  /// Closes the database and clears the cached handle.
  Future<void> close() async {
    final current = _database;
    _database = null;
    if (current != null) await current.close();
  }

  /// Runs a caller operation in an explicit SQLite transaction.
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) async {
    final db = await database;
    return db.transaction(action);
  }
}