import ArgumentParser
import CatalogCore

@main
struct Pinax: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pinax",
    abstract: "Manage a self-hosted image catalog.",
    discussion: CLIExit.helpTable,
    version: PinaxVersion.current,
    subcommands: [
      Initialize.self,
      Migrate.self,
      BackendCommand.self,
      ProjectCommand.self,
      UploadCommand.self,
      AssetListCommand.self,
      AssetShowCommand.self,
      AssetURLCommand.self,
      ObjectCommand.self,
      NoteCommand.self,
      ExportCommand.self,
      TagCommand.self,
      UsageCommand.self,
      OrphansCommand.self,
      ExternalsCommand.self,
      RewriteMapCommand.self,
      RewriteCommand.self,
      RunsCommand.self,
      DoctorCommand.self,
      BackupCommand.self,
      RestoreCommand.self,
      ReindexCommand.self,
      ImportCommand.self,
    ]
  )

  /// ArgumentParser's own `main`, except that a classified runtime error
  /// exits with its status from `CLIExit` and prints no usage.
  static func main() async {
    do {
      var command = try await asyncParseAsRoot(nil)
      if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        try command.run()
      }
    } catch {
      exit(withError: CLIExit.translated(error))
    }
  }
}
