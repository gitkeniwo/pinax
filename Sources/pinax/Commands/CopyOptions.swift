import ArgumentParser
import CatalogCore

/// `--template`: one line per asset, filled in as the app's Copy As formats
/// are.
struct CopyTemplateOption: ParsableArguments {
  @Option(
    name: .long,
    help: ArgumentHelp(
      "Print one line per asset from this template. Placeholders: "
        + CopyTemplate.placeholders.map { "{\($0)}" }.joined(separator: " ") + "."))
  var template: String?

  /// Refuses a template beside `--format`, and one naming a placeholder
  /// that would be printed as written.
  func validate(hasFormat: Bool) throws {
    guard let template else { return }
    guard !hasFormat else {
      throw ValidationError("--template and --format cannot be used together.")
    }
    let unknown = CopyTemplate.unknownPlaceholders(in: template)
    guard unknown.isEmpty else {
      throw ValidationError("Unknown placeholders: \(unknown.joined(separator: ", "))")
    }
  }
}

/// The lines of `template` for catalogued assets, in the order given.
func templateLines(
  _ template: String, for items: [CatalogAssetItem], in database: CatalogDatabasePool
) throws -> [String] {
  let memberships = try CatalogAssets.projectMemberships(
    assetIDs: items.compactMap(\.asset.id), in: database)
  return items.map { item in
    let projects = item.asset.id.flatMap { memberships[$0] } ?? []
    return CopyTemplate.render(
      template, fields: CopyFields(item: item, projects: projects.sorted()))
  }
}
