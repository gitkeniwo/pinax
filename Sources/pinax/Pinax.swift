import ArgumentParser
import CatalogCore

@main
struct Pinax: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pinax",
    abstract: "Manage a self-hosted image catalog.",
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
}
