#
# SessionRmdNotebook.R
#
# Copyright (C) 2009-16 by RStudio, Inc.
#
# Unless you have received this program directly from RStudio pursuant
# to the terms of a commercial license agreement with RStudio, then
# this program is licensed to you under the terms of version 3 of the
# GNU Affero General Public License. This program is distributed WITHOUT
# ANY EXPRESS OR IMPLIED WARRANTY, INCLUDING THOSE OF NON-INFRINGEMENT,
# MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE. Please refer to the
# AGPL (http://www.gnu.org/licenses/agpl-3.0.txt) for more details.
#
#
assign(".rs.notebookVersion", envir = .rs.toolsEnv(), "1.0")

.rs.addJsonRpcHandler("extract_rmd_from_notebook", function(input, output)
{
   if (Encoding(input) == "unknown")  Encoding(input) <- "UTF-8"
   if (Encoding(output) == "unknown") Encoding(output) <- "UTF-8"
   
   # if 'output' already exists, compare file write times to determine
   # whether we really want to overwrite a pre-existing .Rmd
   if (file.exists(output)) {
      inputInfo  <- file.info(input)
      outputInfo <- file.info(output)
      
      if (outputInfo$mtime > inputInfo$mtime)
         stop("'", output, "' exists and is newer than '", input, "'")
   }
   
   contents <- .rs.extractFromNotebook("rnb-document-source", input)
   cat(contents, file = output, sep = "\n")
   
   cachePath <- .rs.rnb.cachePathFromRmdPath(output)
   .rs.hydrateCacheFromNotebook(input, cachePath)
   
   .rs.scalar(TRUE)
})

.rs.addFunction("extractFromNotebook", function(tag, rnbPath)
{
   if (!file.exists(rnbPath))
      stop("no file at path '", rnbPath, "'")
   
   contents <- .rs.readLines(rnbPath)
   
   # find the line hosting the encoded content
   marker <- paste('<!--', tag)
   idx <- NULL
   for (i in seq_along(contents))
   {
      if (.rs.startsWith(contents[[i]], marker))
      {
         idx <- i
         break
      }
   }
   
   if (!length(idx))
      stop("no encoded content with tag '", tag, "' in '", rnbPath, "'")
   
   reDocument <- paste('<!--', tag, '(\\S+) -->')
   rmdEncoded <- sub(reDocument, "\\1", contents[idx])
   .rs.base64decode(rmdEncoded)
})

.rs.addFunction("reRmdChunkBegin", function()
{
   "^[\t >]*```+\\s*\\{[.]?([a-zA-Z]+.*)\\}\\s*$"
})

.rs.addFunction("reRmdChunkEnd", function()
{
   "^[\t >]*```+\\s*$"
})

.rs.addFunction("injectHTMLComments", function(contents,
                                               location,
                                               inject)
{
   # find the injection location
   idx <- NULL
   for (i in seq_along(contents))
   {
      if (contents[[i]] == location)
      {
         idx <- i
         break
      }
   }
   
   if (is.null(idx))
      stop("failed to find injection location '", location, "'")
   
   # generate injection strings
   injection <- paste(vapply(seq_along(inject), FUN.VALUE = character(1), function(i) {
      sprintf('<!-- %s %s -->', names(inject)[i], inject[[i]])
   }), collapse = "\n")
   
   contents <- c(
      contents[1:idx],
      injection,
      contents[(idx + 1):length(contents)]
   )
   
   contents
})

.rs.addFunction("createNotebook", function(inputFile,
                                           outputFile = NULL,
                                           envir = .GlobalEnv)
{
   if (is.null(outputFile))
      outputFile <- .rs.withChangedExtension(inputFile, ext = ".nb.html")
   
   .rs.rnb.render(inputFile, outputFile, envir = envir)
})

.rs.addFunction("rnb.withChunkLocations", function(rmdContents, chunkInfo)
{
   chunkLocs <- grep(.rs.reRmdChunkBegin(), rmdContents, perl = TRUE)
   for (i in seq_along(chunkInfo$chunk_definitions)) {
      info <- chunkInfo$chunk_definitions[[i]]
      
      info$chunk_start <- tail(chunkLocs[chunkLocs < info$row + 1], 1)
      info$chunk_end   <- info$row + 1
      
      chunkInfo$chunk_definitions[[i]] <- info
      
   }
   names(chunkInfo$chunk_definitions) <-
      unlist(lapply(chunkInfo$chunk_definitions, "[[", "chunk_id"))
   chunkInfo
})

.rs.addFunction("readRnbCache", function(rmdPath, cachePath)
{
   if (Encoding(rmdPath) == "unknown")   Encoding(rmdPath) <- "UTF-8"
   if (Encoding(cachePath) == "unknown") Encoding(cachePath) <- "UTF-8"
   
   if (!file.exists(rmdPath))
      stop("No file at path '", rmdPath, "'")
   
   if (!file.exists(cachePath))
      stop("No cache directory at path '", cachePath, "'")
   
   rmdPath <- .rs.normalizePath(rmdPath, winslash = "/", mustWork = TRUE)
   cachePath <- .rs.normalizePath(cachePath, winslash = "/", mustWork = TRUE)
   rmdContents <- .rs.readLines(rmdPath)
   
   # Begin collecting the units that form the Rnb data structure
   rnbData <- list()
   
   # store reference to source path
   rnbData[["source_path"]] <- rmdPath
   rnbData[["cache_path"]]  <- cachePath
   
   # Keep the original source data
   rnbData[["contents"]] <- rmdContents
   
   # Read the chunk information
   chunkInfoPath <- file.path(cachePath, "chunks.json")
   chunkInfo <- .rs.fromJSON(.rs.readFile(chunkInfoPath))
   
   # Augment with start, end locations of chunks
   chunkInfo <- .rs.rnb.withChunkLocations(rmdContents, chunkInfo)
   rnbData[["chunk_info"]] <- chunkInfo
   
   # Read the chunk data
   chunkDirs <- file.path(cachePath, names(chunkInfo$chunk_definitions))
   chunkData <- lapply(chunkDirs, function(dir) {
      files <- list.files(dir, full.names = TRUE)
      contents <- lapply(files, function(file) {
         .rs.readFile(file, binary = .rs.endsWith(file, "png"))
      })
      names(contents) <- basename(files)
      contents
   })
   names(chunkData) <- basename(chunkDirs)
   rnbData[["chunk_data"]] <- chunkData
   
   # Read in the 'libs' directory.
   rnbData[["lib"]] <- list()
   
   libDir <- file.path(cachePath, "lib")
   if (file.exists(libDir)) {
      owd <- setwd(libDir)
      libFiles <- list.files(libDir, recursive = TRUE)
      libData <- lapply(libFiles, .rs.readFile)
      names(libData) <- libFiles
      rnbData[["lib"]] <- libData
      setwd(owd)
   }
   
   rnbData
})

.rs.addFunction("extractHTMLBodyElement", function(html)
{
   begin <- regexpr('<body[^>]*>', html, perl = TRUE)
   end   <- regexpr('</body>', html, perl = TRUE)
   
   contents <- substring(html, begin + attr(begin, "match.length"), end - 1)
   .rs.trimWhitespace(contents)
})

.rs.addFunction("rnb.maskChunks", function(contents, chunkInfo)
{
   masked <- contents
   
   # Extract chunk locations based on the document + chunk info
   chunkRanges <- lapply(chunkInfo$chunk_definitions, function(info) {
      list(start = info$chunk_start,
           end   = info$chunk_end,
           id    = info$chunk_id)
   })
   
   for (range in rev(chunkRanges)) {
      
      beforeText <- if (range$start > 1)
         masked[1:(range$start - 1)]
      
      afterText  <- if (range$end < length(masked))
         masked[(range$end + 1):length(masked)]
      
      masked <- c(
         beforeText,
         paste("<!-- rnb-chunk-id", range$id, "-->"),
         afterText
      )
   }
   
   # mask any remaining chunks (these are chunks which
   # have no associated output in the cache; ie, they
   # were not executed)
   #
   # TODO: respect chunk options here (e.g. 'include = TRUE')
   chunkStarts <- grep(.rs.reRmdChunkBegin(), masked, perl = TRUE)
   chunkEnds   <- grep(.rs.reRmdChunkEnd(), masked, perl = TRUE)
   
   n <- min(length(chunkStarts), length(chunkEnds))
   chunkStarts <- chunkStarts[seq_len(n)]
   chunkEnds   <- chunkEnds[seq_len(n)]
   
   ranges <- mapply(function(x, y) list(start = x, end = y),
                    chunkStarts, chunkEnds, SIMPLIFY = FALSE)
   
   for (range in rev(ranges)) {
      masked <- c(
         masked[1:(range$start - 1)],
         masked[(range$end + 1):length(masked)]
      )
   }
   
   masked
   
})

.rs.addFunction("rnb.fillChunks", function(html, rnbData)
{
   indices <- which(
      .rs.startsWith(html, "<!-- rnb-chunk-id") &
      .rs.endsWith(html, "-->"))
   
   # Record htmlwidget dependencies as we fill chunks
   htmlDependencies <- list()
   
   for (chunkIdx in seq_along(indices))
   {
      i <- indices[[chunkIdx]]
      line <- html[i]
      
      chunkId <- sub('<!-- rnb-chunk-id\\s*(\\S+)\\s*-->', '\\1', line)
      chunkData <- rnbData$chunk_data[[chunkId]]
      chunkDefn <- rnbData$chunk_info$chunk_definitions[[chunkId]]
      if (is.null(chunkData) || is.null(chunkDefn))
         stop("no chunk with id '", chunkId, "'")
      
      # convert to HTML
      htmlList <- .rs.enumerate(chunkData, function(fileName, value) {
         if (.rs.endsWith(fileName, "csv")) {
            .rs.rnb.consoleDataToHtml(value, chunkId, fileName)
         } else if (.rs.endsWith(fileName, "png")) {
            
            tagAttributes <- list(
               "data-rnb-id" = file.path(chunkId, fileName),
               "src" = sprintf("data:image/png;base64,%s", .rs.base64encode(value))
            )
            
            sprintf("<img %s />", .rs.listToHtmlAttributes(tagAttributes))
         } else if (.rs.endsWith(fileName, "html")) {
            
            # parse and record JSON dependencies
            jsonPath <- .rs.withChangedExtension(fileName, "json")
            jsonString <- chunkData[[jsonPath]]
            htmlDependencies <<- c(htmlDependencies, .rs.fromJSON(jsonString))
            
            # emit body of HTML content
            bodyEl <- .rs.extractHTMLBodyElement(value)
            paste("<div>", bodyEl, "</div>", sep = "\n")
         }
      })
      
      # insert into document
      injection <- paste(unlist(htmlList), collapse = "\n")
      
      html[[i]] <- paste(injection, sep = "\n", collapse = "\n")
      chunkIdx <- chunkIdx + 1
   }
   
   # Inject JSON dependency information into document
   # TODO: Resolve duplicates
   htmlInjection <- unlist(lapply(htmlDependencies, function(dep) {
      
      injection <- c()
      
      # Inject a CSS resource
      if (!is.null(dep$stylesheet)) {
         cssPath <- file.path(dep$src$file, dep$stylesheet)
         contents <- .rs.readFile(cssPath, binary = TRUE)
         encoded <- .rs.base64encode(contents)
         htmlAttributes <- list(
            "data-rnb-id" = sprintf("lib/%s-%s/%s", dep$name, dep$version, dep$stylesheet),
            "href" = sprintf("data:text/css;charset=utf8;base64,%s", encoded),
            "rel" = "stylesheet",
            "type" = "text/css"
         )
         cssHtml <- sprintf("<link %s />", .rs.listToHtmlAttributes(htmlAttributes))
         injection <- c(injection, cssHtml)
      }
      
      # Inject a JS resource
      if (!is.null(dep$script))
      {
         jsPath <- file.path(dep$src$file, dep$script)
         contents <- .rs.readFile(jsPath, binary = TRUE)
         encoded <- .rs.base64encode(contents)
         htmlAttributes <- list(
            "data-rnb-id" = sprintf("lib/%s-%s/%s", dep$name, dep$version, dep$script),
            "src" = sprintf("data:application/x-javascript;base64,%s", encoded)
         )
         scriptHtml <- sprintf("<script %s></script>", .rs.listToHtmlAttributes(htmlAttributes))
         injection <- c(injection, scriptHtml)
      }
      
      # Inject other header contents
      rendered <- htmltools:::renderTags(dep)
      headContent <- as.character(rendered$head)
      if (length(headContent) && any(nzchar(headContent)))
         injection <- c(injection, headContent)
      
      paste(injection, collapse = "\n")
   }))
   
   bodyIdx <- tail(grep("^\\s*</head>\\s*$", html, perl = TRUE), n = 1)
   html <- c(
      html[1:(bodyIdx - 1)],
      htmlInjection,
      html[bodyIdx:length(html)]
   )
   
   html
})

.rs.addFunction("rnb.augmentKnitrHooks", function(hooks)
{
   knitHooks <- list()
   optsChunk <- list()
   
   # NOTE: we must install our hooks lazily as the rmarkdown
   # package will install (and override) hooks set here, as
   # hooks set by 'render_markdown()' take precedence.
   tracer <- function(...) {
      
      # save hooks
      knitHooks <<- knitr::knit_hooks$get()
      optsChunk <<- knitr::opts_chunk$get()
      
      # generic hooks for knitr output
      hookNames <- c("source", "chunk", "plot", "text", "output",
                     "warning", "error", "message", "error")
      
      newKnitHooks <- lapply(hookNames, function(hookName) {
         .rs.rnb.annotatedKnitrHook(hookName, knitHooks[[hookName]])
      })
      names(newKnitHooks) <- hookNames
      
      knitr::knit_hooks$set(newKnitHooks)
      
      # hook into 'render' for htmlwidgets
      knitr::opts_chunk$set(
         
         render = function(x, ...) {
            output <- knitr::knit_print(x, ...)
            if (inherits(x, "htmlwidget"))
               return(.rs.rnb.renderHtmlWidget(output))
            output
         }
      )
   }
   
   exit <- function(...) {
      # restore hooks
      knitr::knit_hooks$restore(knitHooks)
      knitr::opts_chunk$restore(optsChunk)
   }
   
   suppressMessages(trace(
      knitr::knit,
      tracer = substitute(tracer),
      exit = substitute(exit),
      print = FALSE
   ))
   
   hooks
})

.rs.addFunction("rnb.htmlAnnotatedOutput", function(output, label)
{
   before <- sprintf("\n<!-- rnb-%s-begin -->\n", label)
   after  <- sprintf("\n<!-- rnb-%s-end -->\n", label)
   paste(before, output, after, sep = "\n")
})

.rs.addFunction("rnb.annotatedKnitrHook", function(label, hook) {
   force(label)
   force(hook)
   function(x, ...) {
      output <- hook(x, ...)
      .rs.rnb.htmlAnnotatedOutput(output, label)
   }
})

.rs.addFunction("rnb.renderHtmlWidget", function(output)
{
   unpreserved <- substring(
      output,
      .rs.nBytes("<!--html_preserve-->") + 1,
      .rs.nBytes(output) - .rs.nBytes("<!--/html_preserve-->")
   )
   
   annotated <- htmltools::htmlPreserve(paste(
      "\n<!-- rnb-htmlwidget-begin -->\n",
      unpreserved,
      "\n<!-- rnb-htmlwidget-end -->\n",
      sep = "\n"
   ))
   
   attributes(annotated) <- attributes(output)
   return(annotated)
})

.rs.addFunction("rnb.htmlNotebook", function(...)
{
   if ("rmarkdown" %in% loadedNamespaces() &&
       exists("html_notebook", envir = asNamespace("rmarkdown")))
   {
      return(rmarkdown::html_notebook(...))
   }
   
   format <- rmarkdown::html_document(code_folding = "show",
                                      theme = "cerulean",
                                      highlight = "textmate",
                                      ...)
   
   format$knitr <- .rs.rnb.augmentKnitrHooks(format$knitr)
   format
})

.rs.addFunction("rnb.render", function(inputFile,
                                       outputFile,
                                       outputFormat = .rs.rnb.htmlNotebook(),
                                       rmdContents = .rs.readFile(inputFile),
                                       envir = .GlobalEnv)
{
   renderOutput <- tempfile("rnb-render-output-", fileext = ".html")
   outputOptions <- list(self_contained = TRUE, keep_md = TRUE)
   
   rmarkdown::render(input = inputFile,
                     output_format = outputFormat,
                     output_file = renderOutput,
                     output_options = outputOptions,
                     encoding = "UTF-8",
                     envir = envir,
                     quiet = TRUE)
   
   
   # read the rendered file
   rnbContents <- .rs.readLines(renderOutput)
   
   # generate base64-encoded versions of .Rmd source, .md sidecar
   rmdEncoded <- .rs.base64encode(paste(rmdContents, collapse = "\n"))
   
   # inject document contents into rendered file
   # (i heard you like documents, so i put a document in your document)
   rnbContents <- .rs.injectHTMLComments(
      rnbContents,
      "</body>",
      list("rnb-document-source" = rmdEncoded)
   )
   
   # write our .Rnb to file and we're done!
   cat(rnbContents, file = outputFile, sep = "\n")
   invisible(outputFile)
   
})

.rs.addFunction("createNotebookFromCacheData", function(rnbData,
                                                        outputFile,
                                                        envir = .GlobalEnv)
{
   # first, render our .Rmd to transform markdown to html
   contents <- rnbData$contents
   chunkInfo <- rnbData$chunk_info
   
   # mask out chunks (replace with placeholders w/id)
   masked <- .rs.rnb.maskChunks(contents, chunkInfo)
   
   # use pandoc to convert md to html
   inputTemp  <- tempfile("rnb-tempfile-input-", fileext = ".md")
   outputTemp <- tempfile("rnb-tempfile-output-", fileext = ".html")
   cat(masked, file = inputTemp, sep = "\n")
   
   # render our notebook
   .rs.rnb.render(inputFile = inputTemp,
                  outputFile = outputTemp,
                  rmdContents = contents,
                  envir = envir)
   
   # read the HTML
   html <- .rs.readLines(outputTemp)
   
   # replace chunk placeholders with their actual data
   html <- .rs.rnb.fillChunks(html, rnbData)
   
   html
})

.rs.addFunction("createNotebookFromCache", function(rmdPath, outputPath = NULL)
{
   if (is.null(outputPath))
      outputPath <- .rs.withChangedExtension(rmdPath, "Rnb")
   
   cachePath <- .rs.rnb.cachePathFromRmdPath(rmdPath)
   if (!file.exists(cachePath)) {
      
      # render our notebook, but don't evaluate any R code
      eval <- knitr::opts_chunk$get("eval")
      knitr::opts_chunk$set(eval = FALSE)
      on.exit(knitr::opts_chunk$set(eval = eval), add = TRUE)
      
      # render our notebook
      .rs.rnb.render(inputFile = rmdPath,
                     outputFile = outputPath)
      
      return(TRUE)
   }
   
   rnbData <- .rs.readRnbCache(rmdPath, cachePath)
   html <- .rs.createNotebookFromCacheData(rnbData, outputPath)
   
   # inject cache data
   html <- .rs.rnb.injectCacheData(html, rnbData, cachePath)
   
   # write to file
   cat(html, file = outputPath, sep = "\n")
   outputPath
})

.rs.addFunction("rnb.generateEncodedCacheResource", function(file,
                                                             html,
                                                             rnbData,
                                                             cachePath)
{
   ext <- tools::file_ext(file)
   encoded <- if (ext %in% c("png", "js"))
   {
      "@src"
   }
   else
   {
      fullPath <- file.path(cachePath, file)
      contents <- .rs.readFile(fullPath, binary = TRUE)
      .rs.base64encode(contents)
   }
   
   paste(file, encoded, sep = ":")
})

.rs.addFunction("rnb.injectCacheData", function(html, rnbData, cachePath)
{
   files <- list.files(cachePath, recursive = TRUE)
   contents <- unlist(lapply(files, function(file) {
      .rs.rnb.generateEncodedCacheResource(file, html, rnbData, cachePath)
   }))
   
   injection <- paste(
      "<!-- rnb-cache-data-begin",
      paste(paste("   ", contents), collapse = "\n"),
      "rnb-cache-data-end -->",
      sep = "\n"
   )
   
   idx <- grep("</body>", html)
   html <- c(
      html[1:idx],
      injection,
      html[(idx + 1):length(html)])
   
   html
})

.rs.addFunction("rnb.cachePathFromRmdPath", function(rmdPath)
{
   .Call("rs_chunkCacheFolder", rmdPath)
})

.rs.addFunction("rnb.parseConsoleData", function(data)
{
   csvData <- read.csv(
      text = data,
      encoding = "UTF-8",
      header = FALSE,
      stringsAsFactors = FALSE
   )
   
   names(csvData) <- c("type", "text")
   csvData
})

.rs.addFunction("rnb.consoleDataToHtml", function(data, chunkId, fileName)
{
   csvData <- .rs.rnb.parseConsoleData(data)
   cutpoints <- .rs.cutpoints(csvData$type)
   
   ranges <- Map(
      function(start, end) list(start = start, end = end),
      c(1, cutpoints),
      c(cutpoints - 1, nrow(csvData))
   )
   
   splat <- lapply(ranges, function(range) {
      
      type <- csvData$type[[range$start]]
      collapse <- if (type == 0) "\n" else ""
      
      pasted <- paste(csvData$text[range$start:range$end], collapse = collapse)
      result <- .rs.trimWhitespace(pasted)
      if (!nzchar(result))
         return(NULL)
      
      if (type == 1 || type == 2)
         result <- paste("##", gsub("\n", "\n## ", result, fixed = TRUE))
      
      attr(result, ".class") <- if (type == 0) "r"
      result
   })
   
   filtered <- Filter(Negate(is.null), splat)
   html <- lapply(filtered, function(el) {
      class <- attr(el, ".class")
      result <- if (is.null(class)) {
         sprintf(
            "<pre><code>%s</code></pre>",
            el
         )
      } else {
         sprintf(
            "<pre class=\"%s\"><code>%s</code></pre>",
            class,
            el
         )
      }
      result
   })
   
   paste(unlist(html), collapse = "\n")
})

.rs.addFunction("scrapeHtmlAttributes", function(line)
{
   reData <- '([[:alnum:]_-]+)[[:space:]]*=[[:space:]]*"(\\\\.|[^"])+"'
   reMatches <- gregexpr(reData, line)[[1]]
   starts <- c(reMatches)
   ends   <- starts + attr(reMatches, "match.length") - 1
   stripped <- substring(line, starts, ends)
   equalsIndex <- regexpr("=", stripped, fixed = TRUE)
   lhs <- substring(stripped, 1, equalsIndex - 1)
   rhs <- substring(stripped, equalsIndex + 2, nchar(stripped) - 1)
   names(rhs) <- lhs
   as.list(rhs)
})

.rs.addFunction("listToHtmlAttributes", function(list)
{
   paste(
      names(list),
      .rs.surround(unlist(list), with = "\""),
      sep = "=",
      collapse = " "
   )
})

.rs.addFunction("rnb.hydrateFromAttribute", function(id,
                                                     attribute,
                                                     rnbContents,
                                                     targetPath)
{
   target <- sprintf('data-rnb-id="%s"', id)
   idx <- grep(target, rnbContents, fixed = TRUE)
   
   if (length(idx) != 1)
      stop("failed to discover element with chunk id '", id, "'")
   
   line <- rnbContents[[idx]]
   scraped <- .rs.scrapeHtmlAttributes(line)
   element <- scraped[[attribute]]
   data <- sub("^.*;base64,", "", element)
   decoded <- .rs.base64decode(data, TRUE)
   writeBin(decoded, con = targetPath)
   
   TRUE
})

.rs.addFunction("rnb.hydrateFromBase64", function(encodedContents,
                                                  targetPath)
{
   parentPath <- dirname(targetPath)
   if (!dir.exists(parentPath))
      if (!dir.create(parentPath, recursive = TRUE))
         stop("failed to create cache path '", parentPath, "'")
   
   decoded <- .rs.base64decode(encodedContents, TRUE)
   writeBin(decoded, con = targetPath)
   TRUE
})

.rs.addFunction("hydrateCacheFromNotebook", function(rnbPath, cachePath = NULL)
{
   if (is.null(cachePath)) {
      rmdPath <- .rs.withChangedExtension(rnbPath, "Rmd")
      cachePath <- .rs.rnb.cachePathFromRmdPath(rmdPath)
   }
   
   rnbContents <- .rs.readLines(rnbPath)
   startIdx <- grep("<!-- rnb-cache-data-begin", rnbContents) + 1
   endIdx   <- grep("rnb-cache-data-end -->", rnbContents) - 1
   
   status <- lapply(startIdx:endIdx, function(i) {
      
      line <- rnbContents[[i]]
      colonIdx <- regexpr(":", line, fixed = TRUE)
      filePath <- .rs.trimWhitespace(substring(line, 1, colonIdx - 1))
      encodedContents <- substring(line, colonIdx + 1)
      targetPath <- file.path(cachePath, filePath)
      .rs.ensureDirectory(dirname(targetPath))
      
      if (.rs.startsWith(encodedContents, "@")) {
         .rs.rnb.hydrateFromAttribute(
            filePath,
            substring(encodedContents, 2),
            rnbContents,
            targetPath)
      } else {
         .rs.rnb.hydrateFromBase64(
            encodedContents,
            targetPath)
      }
      
   })
   
   cachePath
   
})

.rs.addFunction("evaluateChunkOptions", function(options)
{
  opts <- list()
  tryCatch({
    # if this is the setup chunk, it's not included by default
    setupIndicator <- "r setup"
    if (identical(substring(options, 1, nchar(setupIndicator)), 
                  setupIndicator)) {
      opts$include <- FALSE
    }

    # remove leading text from the options
    options <- sub("^[^,]*,\\s*", "", options)

    # parse them, then merge with the defaults
    opts <- .rs.mergeLists(opts,
                           eval(parse(text = paste("list(", options, ")"))))
                           
  },
  error = function(e) {})

  .rs.scalarListFromList(opts)
})
