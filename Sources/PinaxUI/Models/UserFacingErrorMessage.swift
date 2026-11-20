import CatalogCore
import Foundation

/// Converts failures into deliberately user-facing prose without reflecting
/// the error value. Unknown errors may carry URLs, requests, or credentials in
/// associated values, so their debug descriptions must never reach the UI.
enum UserFacingErrorMessage {
  static func resolve(_ error: Error) -> String {
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription,
      !description.isEmpty
    {
      return description
    }

    switch error {
    case let error as CatalogConfigurationError:
      return error.description
    case let error as UploadPipelineError:
      return error.description
    case let error as CatalogDeletionError:
      return error.description
    case let error as ExternalMigrationError:
      return error.description
    case let error as UploadCatalogError:
      return error.description
    case let error as RewriteRunError:
      return error.description
    default:
      return "The operation could not be completed."
    }
  }
}
