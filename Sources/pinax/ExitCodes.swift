import ArgumentParser
import CatalogCore
import Foundation

/// The one table of what `pinax` exits with, after sysexits(3). A runtime
/// error listed in `code(for:)` is printed as `Error: <message>` without
/// usage. Everything else is left to ArgumentParser: a bad command line
/// exits 64 with usage, any other error 1.
enum CLIExit {
  static let failure: Int32 = 1
  static let usage: Int32 = 64
  /// An asset, backend, project, source, file, or run that is not there.
  static let notFound: Int32 = 66
  /// The object store or a public URL failed or did not answer.
  static let remote: Int32 = 69
  /// A safeguard refused.
  static let refused: Int32 = 77
  /// A backend's credentials are missing or were not supplied.
  static let credentials: Int32 = 78

  /// What `pinax --help` prints.
  static let helpTable = """
    Exit status:
      0   success
      1   other failure
      64  bad argument
      66  not found
      69  remote failure
      77  refused by a safeguard
      78  credentials missing
    """

  /// The status of a classified error, or nil for one ArgumentParser
  /// reports as before.
  static func code(for error: Error) -> Int32? {
    switch error {
    case let error as CLIError:
      return error.exitCode
    case let error as AssetCatalogError:
      switch error {
      case .assetNotFound, .projectNotFound, .unresolvedIdentifiers: return notFound
      case .unlinkBlockedByLiveUsage, .unlinkBlockedForAssets: return refused
      case .invalidSHA256Prefix, .ambiguousIdentifier, .invalidTag: return nil
      }
    case let error as CatalogConfigurationError:
      switch error {
      case .backendNotFound, .projectNotFound, .sourceNotFound, .oldDomainNotFound:
        return notFound
      case .domainOfOtherBackend: return usage
      default: return nil
      }
    case let error as UsageCatalogError:
      switch error {
      case .projectNotFound: return notFound
      case .emptyScanRejected: return refused
      default: return nil
      }
    case let error as ManifestError:
      if case .projectNotFound = error { return notFound }
      return nil
    case let error as UsageScanError:
      if case .sourceNotFound = error { return notFound }
      return nil
    case let error as CatalogRestoreError:
      if case .catalogNotEmpty = error { return refused }
      return nil
    case let error as CatalogDeletionError:
      switch error {
      case .noSuchPendingDeletion, .objectGone: return notFound
      case .tooMany, .notArchived, .unsafeKey, .sharedKey, .stillUsed, .restoreNeedsRemoteCheck,
        .objectNotOurs, .restoreConflict:
        return refused
      }
    case let error as ObjectDeleteError:
      switch error {
      case .unsafeKey: return refused
      case .permissionDenied, .http: return remote
      }
    case is DeletionRemoteError:
      return credentials
    case is DatabaseLocationError:
      return refused
    case is RunCommandsRequired:
      return refused
    case let error as S3UploaderError:
      switch error {
      case .http, .invalidResponse: return remote
      case .invalidEndpoint, .invalidMetadataKey, .nonASCIIHeaderValue: return nil
      }
    case let error as ObjectReadError:
      switch error {
      case .notFound: return notFound
      case .lengthMismatch, .missingETag: return remote
      }
    case is PublicObjectFetchError, is URLError:
      return remote
    case let error as RewriteRunError:
      switch error {
      case .runNotFound, .unknownSources: return notFound
      case .notAPreview, .planChanged, .sourcesNotAllowed, .targetsNotVerified: return refused
      }
    case is RewriteApplyError:
      return refused
    case is RewritePlanError:
      return usage
    case let error as RewriteCommandError:
      switch error {
      case .mapNotFound: return notFound
      case .badMap: return usage
      }
    case let error as DomainMigrationError:
      switch error {
      case .invalidDomain, .sameAsCurrent, .notAnOldDomain: return usage
      case .noProjects: return notFound
      case .targetsNotVerified, .prefixMoved: return refused
      }
    case let error as ExternalMigrationError:
      switch error {
      case .noTargets: return usage
      case .noBackend, .backendsDiffer: return notFound
      case .busy, .cacheInvalid: return refused
      }
    case let error as ExternalsMigrateError:
      switch error {
      case .notInOtherDomains: return usage
      case .noCredentials: return credentials
      case .refused: return refused
      }
    default:
      return nil
    }
  }

  /// For a command that reports several failures itself: their status when
  /// they all share one, else `failure`.
  static func code(forAll errors: [Error]) -> Int32 {
    let codes = Set(errors.map { code(for: $0) ?? failure })
    return codes.count == 1 ? codes.first! : failure
  }

  /// A classified error is written to standard error, in the words
  /// ArgumentParser would use, and becomes its `ExitCode`; any other error
  /// is returned unchanged.
  static func translated(_ error: Error) -> Error {
    guard let code = code(for: error) else { return error }
    FileHandle.standardError.write(Data("Error: \(Pinax.message(for: error))\n".utf8))
    return ExitCode(code)
  }
}

/// A runtime error the CLI raises itself. `ValidationError` is for a bad
/// command line only, because it prints usage and exits 64.
struct CLIError: Error, CustomStringConvertible {
  let exitCode: Int32
  let description: String

  static func failure(_ message: String) -> CLIError {
    CLIError(exitCode: CLIExit.failure, description: message)
  }

  static func notFound(_ message: String) -> CLIError {
    CLIError(exitCode: CLIExit.notFound, description: message)
  }

  static func refused(_ message: String) -> CLIError {
    CLIError(exitCode: CLIExit.refused, description: message)
  }

  static func credentials(_ message: String) -> CLIError {
    CLIError(exitCode: CLIExit.credentials, description: message)
  }
}
