import ArgumentParser
import CatalogCore

struct Initialize: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Create and migrate the Pinax catalog database."
  )

  mutating func run() throws {
    try migrateDatabase()
  }
}

struct Migrate: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Apply pending catalog database migrations."
  )

  mutating func run() throws {
    try migrateDatabase()
  }
}

private func migrateDatabase() throws {
  let databaseURL = try DBLocation.resolve()
  let database = try Database.open(
    at: databaseURL,
    onLocationWarning: writeDatabaseLocationWarning
  )
  try Database.migrate(database)
  print(databaseURL.path)
}
