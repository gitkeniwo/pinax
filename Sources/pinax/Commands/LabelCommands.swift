import ArgumentParser
import CatalogCore

struct LabelCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "label",
    abstract: "Manage color labels.",
    subcommands: [LabelListCommand.self]
  )
}

struct LabelListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls",
    abstract: "List the color labels on active assets, with counts."
  )

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() async throws {
    let labels = try await CatalogAssets.labelSummaries(in: openCatalogDatabase())
    let counts = labels.map { NameCountJSON(name: $0.label.rawValue, count: $0.assetCount) }
    if format == .json {
      print(try encodedJSON(LabelListDocument(labels: counts)))
      return
    }
    printNameCounts(counts)
  }
}

struct LabelListDocument: Encodable {
  let schema = "pinax.labels.v1"
  let labels: [NameCountJSON]
}
