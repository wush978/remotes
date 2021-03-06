#' Attempts to install a package directly from GitHub.
#'
#' This function is vectorised on \code{repo} so you can install multiple
#' packages in a single command.
#'
#' @param repo Repository address in the format
#'   \code{username/repo[/subdir][@@ref|#pull]}. Alternatively, you can
#'   specify \code{subdir} and/or \code{ref} using the respective parameters
#'   (see below); if both is specified, the values in \code{repo} take
#'   precedence.
#' @param username User name. Deprecated: please include username in the
#'   \code{repo}
#' @param ref Desired git reference. Could be a commit, tag, or branch
#'   name, or a call to \code{\link{github_pull}}. Defaults to \code{"master"}.
#' @param subdir subdirectory within repo that contains the R package.
#' @param auth_token To install from a private repo, generate a personal
#'   access token (PAT) in \url{https://github.com/settings/applications} and
#'   supply to this argument. This is safer than using a password because
#'   you can easily delete a PAT without affecting any others. Defaults to
#'   the \code{GITHUB_PAT} environment variable.
#' @param host GitHub API host to use. Override with your GitHub enterprise
#'   hostname, for example, \code{"github.hostname.com/api/v3"}.
#' @param ... Other arguments passed on to \code{install.packages}.
#' @details
#' Attempting to install from a source repository that uses submodules
#' raises a warning. Because the zipped sources provided by GitHub do not
#' include submodules, this may lead to unexpected behaviour or compilation
#' failure in source packages. In this case, cloning the repository manually
#' may yield better results.
#' @export
#' @seealso \code{\link{github_pull}}
#' @examples
#' \dontrun{
#' install_github("klutometis/roxygen")
#' install_github("wch/ggplot2")
#' install_github(c("rstudio/httpuv", "rstudio/shiny"))
#' install_github(c("hadley/httr@@v0.4", "klutometis/roxygen#142",
#'   "mfrasca/r-logging/pkg"))
#'
#' # To install from a private repo, use auth_token with a token
#' # from https://github.com/settings/applications. You only need the
#' # repo scope. Best practice is to save your PAT in env var called
#' # GITHUB_PAT.
#' install_github("hadley/private", auth_token = "abc")
#'
#' }
install_github <- function(repo, username = NULL,
                           ref = "master", subdir = NULL,
                           auth_token = github_pat(),
                           host = "api.github.com", ...) {

  remotes <- lapply(repo, github_remote, username = username, ref = ref,
    subdir = subdir, auth_token = auth_token, host = host)

  install_remotes(remotes, ...)
}

github_remote <- function(repo, username = NULL, ref = NULL, subdir = NULL,
                       auth_token = github_pat(), sha = NULL,
                       host = "api.github.com") {

  meta <- parse_git_repo(repo)
  meta <- github_resolve_ref(meta$ref %||% ref, meta)

  if (is.null(meta$username)) {
    meta$username <- username %||% getOption("github.user") %||%
      stop("Unknown username.")
    warning("Username parameter is deprecated. Please use ",
      username, "/", repo, call. = FALSE)
  }

  remote("github",
    host = host,
    repo = meta$repo,
    subdir = meta$subdir %||% subdir,
    username = meta$username,
    ref = meta$ref,
    sha = sha,
    auth_token = auth_token
  )
}

#' @export
remote_download.github_remote <- function(x, quiet = FALSE) {
  if (!quiet) {
    message("Downloading GitHub repo ", x$username, "/", x$repo, "@", x$ref)
  }

  dest <- tempfile(fileext = paste0(".zip"))
  src_root <- paste0("https://", x$host, "/repos/", x$username, "/", x$repo)
  src <- paste0(src_root, "/zipball/", utils::URLencode(x$ref, reserved = TRUE))

  if (github_has_submodules(x)) {
    warning("GitHub repo contains submodules, may not function as expected!",
            call. = FALSE)
  }

  download(dest, src, auth_token = x$auth_token)
}

github_has_submodules <- function(x) {
  src_root <- paste0("https://", x$host, "/repos/", x$username, "/", x$repo)
  src_submodules <- paste0(src_root, "/contents/.gitmodules?ref=", x$ref)

  tmp <- tempfile()
  res <- tryCatch(
    download(tmp, src_submodules, auth_token = x$auth_token),
    error = function(e) e
  )
  if (methods::is(res, "error")) return(FALSE)

  ## download() sometimes just downloads the error page, because
  ## the libcurl backend in download.file() is broken
  ## If the request was successful (=submodules exist), then it has an
  ## 'sha' field.
  sha <- tryCatch(
    fromJSONFile(tmp)$sha,
    error = function(e) e
  )
  ! methods::is(sha, "error") && ! is.null(sha)
}

#' @export
remote_metadata.github_remote <- function(x, bundle = NULL, source = NULL) {
  # Determine sha as efficiently as possible
  if (!is.null(x$sha)) {
    # Might be cached already (because re-installing)
    sha <- x$sha
  } else if (!is.null(bundle)) {
    # Might be able to get from zip archive
    sha <- git_extract_sha1(bundle)
  } else {
    # Otherwise can use github api
    sha <- github_commit(x$username, x$repo, x$ref)$sha
  }

  list(
    RemoteType = "github",
    RemoteHost = x$host,
    RemoteRepo = x$repo,
    RemoteUsername = x$username,
    RemoteRef = x$ref,
    RemoteSha = sha,
    RemoteSubdir = x$subdir,
    # Backward compatibility for packrat etc.
    GithubRepo = x$repo,
    GithubUsername = x$username,
    GithubRef = x$ref,
    GithubSHA1 = sha,
    GithubSubdir = x$subdir
  )
}

#' GitHub references
#'
#' Use as \code{ref} parameter to \code{\link{install_github}}.
#' Allows installing a specific pull request or the latest release.
#'
#' @param pull The pull request to install
#' @seealso \code{\link{install_github}}
#' @rdname github_refs
#' @export
github_pull <- function(pull) structure(pull, class = "github_pull")

#' @rdname github_refs
#' @export
github_release <- function() structure(NA_integer_, class = "github_release")

github_resolve_ref <- function(x, params) UseMethod("github_resolve_ref")

#' @export
github_resolve_ref.default <- function(x, params) {
  params$ref <- x
  params
}

#' @export
github_resolve_ref.NULL <- function(x, params) {
  params$ref <- "master"
  params
}

#' @export
github_resolve_ref.github_pull <- function(x, params) {
  # GET /repos/:user/:repo/pulls/:number
  path <- file.path("repos", params$username, params$repo, "pulls", x)
  response <- tryCatch(
    github_GET(path),
    error = function(e) e
  )

  ## Just because libcurl might download the error page...
  if (methods::is(response, "error") || is.null(response$head)) {
    stop("Cannot find GitHub pull request ", params$username, "/",
         params$repo, "#", x)
  }

  params$username <- response$head$user$login
  params$ref <- response$head$ref
  params
}

# Retrieve the ref for the latest release
#' @export
github_resolve_ref.github_release <- function(x, params) {
  # GET /repos/:user/:repo/releases
  path <- paste("repos", params$username, params$repo, "releases", sep = "/")
  response <- tryCatch(
    github_GET(path),
    error = function(e) e
  )

  if (methods::is(response, "error") || !is.null(response$message)) {
    stop("Cannot find repo ", params$username, "/", params$repo, ".")
  }

  if (length(response) == 0L)
    stop("No releases found for repo ", params$username, "/", params$repo, ".")

  params$ref <- response[[1L]]$tag_name
  params
}

#' Parse a concise GitHub repo specification
#'
#' The current format is:
#' \code{[username/]repo[/subdir][#pull|@ref|@*release]}
#' The \code{*release} suffix represents the latest release.
#'
#' @param repo Character scalar, the repo specification.
#' @return List with members: \code{username}, \code{repo}, \code{subdir}
#'   \code{ref}, \code{pull}, \code{release}. Members that do not
#'   appear in the input repo specification are omitted.
#'
#' @export
#' @examples
#' parse_github_repo_spec("metacran/crandb")
#' parse_github_repo_spec("jeroenooms/curl@v0.9.3")
#' parse_github_repo_spec("jimhester/covr#47")
#' parse_github_repo_spec("hadley/dplyr@*release")
#' parse_github_repo_spec("mangothecat/remotes@550a3c7d3f9e1493a2ba")

parse_github_repo_spec <- function(repo) {
  username_rx <- "(?:([^/]+)/)?"
  repo_rx <- "([^/@#]+)"
  subdir_rx <- "(?:/([^@#]*[^@#/])/?)?"
  ref_rx <- "(?:@([^*].*))"
  pull_rx <- "(?:#([0-9]+))"
  release_rx <- "(?:@([*]release))"
  ref_or_pull_or_release_rx <- sprintf("(?:%s|%s|%s)?", ref_rx, pull_rx, release_rx)
  github_rx <- sprintf("^(?:%s%s%s%s|(.*))$",
    username_rx, repo_rx, subdir_rx, ref_or_pull_or_release_rx)

  param_names <- c("username", "repo", "subdir", "ref", "pull", "release", "invalid")
  replace <- stats::setNames(sprintf("\\%d", seq_along(param_names)), param_names)
  params <- lapply(replace, function(r) gsub(github_rx, r, repo, perl = TRUE))
  if (params$invalid != "")
    stop(sprintf("Invalid git repo: %s", repo))
  params <- params[viapply(params, nchar) > 0]

  params
}

parse_git_repo <- function(repo) {
  params <- parse_github_repo_spec(repo)

  if (!is.null(params$pull)) {
    params$ref <- github_pull(params$pull)
    params$pull <- NULL
  }

  if (!is.null(params$release)) {
    params$ref <- github_release()
    params$release <- NULL
  }

  params
}
