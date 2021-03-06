# a4axval.R - DESC
# /a4axval.R

# Copyright Iago MOSQUEIRA (WMR), 2020
# Author: Iago MOSQUEIRA (WMR) <iago.mosqueira@wur.nl>
#
# Distributed under the terms of the EUPL-1.2

globalVariables(c("final", "y", "pred"))

# TODO
# - retro + forecast plot
# - xval takes lists for fmod and srmod
# - show Mohn's rho, sa (fwd)
# - plot(F, SSB)
# - DO runstest
# - nkratio dim[2] / k

# xval {{{

#' Compute a retrospective hindcast cross-validation of a4a stock and indices
#'
#' @param stock Input FLStock object.
#' @param indices Input FLIndices object.
#' @param nyears=5 Number iof years for retrospective.
#' @param nsq=3 Number of years for average biology and selectivity.
#' @param ... Any arguments for the call to *sca*.
#'
#' @return A list containing elements 'stock', of class *FLStocks*, and
#' 'indices', a list of *FLIndices* objects.

xval <- function(stock, indices, nyears=5, nsq=3, fixed.ks=FALSE, ...) {

  fy <- dims(stock)$maxyear
  y0 <- dims(stock)$minyear

  # CHECK submodels
  mods <- list(...)

  foo <- function(x)
    sum(grepl("te\\(*", labels(terms(x))) & grepl("year", labels(terms(x))) |
    grepl("s\\(*", labels(terms(x))) & grepl("year", labels(terms(x))))

  smyr <- lapply(mods, function(x){
    if(is(x, "list"))
      unlist(lapply(x, foo))
    else
      foo(x)
  })

  if(any(unlist(smyr) > 0))
    warning("Submodels using s(year) or te(year) should have 'k' changed in retro")

  # SELECT indices that fall within retro year range
  iyrs <- unlist(lapply(indices, function(x) dims(x)$maxyear)) >= (fy - nyears)

  if(!all(iyrs))
    warning(paste("FLIndices outside of year range are excluded from xval:",
      paste(names(indices)[!iyrs], collapse=", ")))

  # FILL index wt using stock.wt
  indices <- lapply(indices, function(x) {
    dmns <- dimnames(index(x))
    if(all(is.na(catch.wt(x))))
      catch.wt(x) <- stock.wt(stock)[dmns$age, dmns$year]
    return(x)
    }
  )

  # LOOP

  retro <- foreach(y=seq(fy, fy - nyears)) %dopar% {

    # RUN
    fit <- sca(window(stock, end=y), lapply(indices, window, end=y), ...)

    # UPDATE
    stock.n(stock)[, ac(y0:y)] <- stock.n(fit) 
    harvest(stock)[, ac(y0:y)] <- harvest(fit)

    # PREDICT stock, unless y == fy
    if(y < fy) {

     # SET future SELEX, WTs
      fyrs <- ac(seq(y-nsq-1, y))

      harvest(stock)[, ac(y+1)] <- yearMeans(harvest(stock)[, fyrs])
      stock.wt(stock)[, ac(y+1)] <- yearMeans(stock.wt(stock)[, fyrs])
      catch.wt(stock)[, ac(y+1)] <- yearMeans(catch.wt(stock)[, fyrs])
      landings.wt(stock)[, ac(y+1)] <- yearMeans(landings.wt(stock)[, fyrs])
      discards.wt(stock)[, ac(y+1)] <- yearMeans(discards.wt(stock)[, fyrs])

      # REC
      srr <- predictModel(model=rec~a,
        params=FLPar(a=exp(mean(log(rec(stock))))))

      # FWD
      pred <- fwd(stock, control=fwdControl(year=seq(y+1, fy),
        quant="catch", value=catch(stock)[, ac(seq(y+1, fy))]), sr=srr)
    } else {
      pred <- stock
    }

    # PREDICT FLIndices

    qs <- predict(fit)$qmodel

    ihat <- mapply(function(a, b) {
     
      # GET dims
      dmns <- dimnames(a)
      dis <- dims(a)
      timf <- mean(range(b)[c("startf", "endf")])

      # UPDATE index
      a <- window(a, end=fy)

      # EXTEND cachabilities if empty
      if(y < fy) {
        a[, ac(seq(dis$maxyear + 1, fy))] <-
          yearMeans(a[, ac(seq(dis$maxyear - nsq + 1, dis$maxyear))])
      }
      
      # COMPUTE predicted index
      index(b) <- a * stock.n(pred)[dmns$age, ac(seq(dis$minyear, fy))] *
        exp(-z(pred)[dmns$age, ac(seq(dis$minyear, fy))] * timf)

      # STORE catchabilities
      index.q(b) <- a

      return(b)

      }, a=qs[iyrs], b=indices[iyrs], SIMPLIFY=FALSE)

    name(pred) <- paste(name(pred), y, sep="_")
    desc(pred) <- paste(".", desc(pred), "xval -", y)

    list(stock=pred, indices=ihat)
  }

  # OUTPUT: stocks (FLStocks)
  stocks <- FLStocks(lapply(retro, "[[", "stock"))
  names(stocks) <- seq(fy, fy - nyears)

  # indices (list of FLIndices))
  indices <- lapply(retro, function(x) FLIndices(x$indices))
  names(indices) <- seq(fy, fy - nyears)

  list(stocks=stocks, indices=indices)
} # }}}

# mase {{{

#' Compute mean absolute scaled error (MASE)
#'
#' Franses, PH. "A note on the Mean Absolute Scaled Error". International Journal of Forecasting. 32 (1): 20–22. doi:10.1016/j.ijforecast.2015.03.008.
#'
#' @param ref Reference or naive prediction.
#' @param preds Predicitions to compare to reference.
#' @param order Are predictions in 'inverse' (default) or 'ahead' order.
#'
#' @return A numeric vector of the same length as 'preds'.

setGeneric("mase", function(ref, preds, ...) standardGeneric('mase'))

setMethod("mase", signature(ref="FLQuant", preds="FLQuants"),
  function(ref, preds, order=c("inverse", "ahead")) {

    # SET dims
    fy <- dims(ref)$maxyear
    nyears <- length(preds)

    # REVERSE if ahead
    if(order[1] == "ahead")
      preds <- preds[rev(seq(length(preds)))]

    # ADD names if missing
    if(is.null(names(preds)))
      names(preds) <- seq(fy - 1, fy - nyears)

    # \sum_{t=T-h+1}^{T} |\hat{y}_t - y_t|
    num  <- abs(log(mapply(function(x, y) x[, y], preds,
      y=ac(seq(fy, fy - nyears + 1)), SIMPLIFY=TRUE)) -
      log(ref[, ac(seq(fy, fy - nyears + 1))]))

    # \sum_{t=T-h+1}^{T} |y_t - y_{t-1}|
    den <- abs(log(ref[, ac(seq(fy, fy - nyears + 1))]) -
      log(ref[, ac(seq(fy - 1, fy - nyears))]))

    mase <- (1 / nyears * sum(num)) / (1 / nyears * sum(den))

    return(mase)
  }
)

setMethod("mase", signature(ref="FLIndices", preds="list"),
  function(ref, preds, order="inverse", wt="missing") {

    # CHECK classes in list
    if(!all(unlist(lapply(preds, is, "FLIndices"))))
      stop("All elements in 'preds' list must be of class 'FLIndices'.")

    if(!all(unlist(lapply(preds, length)) == length(ref)))
      stop("'FLIndices' in 'preds' must have the same length as 'ref'.")

    # TODO CHECK names and warn if first matches last year of ref

    indices <- c(list(ref), preds)

    # TODO PARSE wt and add to indices

    res <- unlist(lapply(setNames(nm=names(indices[[1]])), function(i) {
      # COMPUTE index in biomass
      flqs <- lapply(indices, function(x) {
        if(is(x, "FLIndexBiomass"))
          index(x[[i]])
        else
          quantSums(index(x[[i]]) * catch.wt(x[[i]]))
      })
      mase(flqs[[1]], FLQuants(flqs[-1]), order=order)
    }))

    return(res)
  }
)
# }}}

# data.tables {{{

dtp <- function(flis, y0) {

  rbindlist(lapply(names(flis), function(i) {
    pred <- pmin(an(i) + 1, an(names(flis)[1]))
    data.table(cbind(as.data.frame(lapply(flis[[ac(i)]], function(x) {
      # COMPUTE Total abundance in biomass
      window(quantSums(index(x) * catch.wt(x)), start=y0, end=pred)
    }), drop=TRUE, qname="index"), final=i, pred=pred))}))
}

dto <- function(flis, y0) {

  data.table(as.data.frame(lapply(flis, function(x) {
    dmns <- dimnames(x)
    window(quantSums(index (x) * catch.wt(x)), start=y0)
  }), drop=TRUE, qname="index"))

}
# }}}

# plotXval (FLIndices, list) {{{

#' Plot of FLIndices cross-validation by retrospective hindcast
#'
#' @param x An *FLIndices* object of the original observations
#' @param y A list contaning *FLIndices* objects returned by *xval*.
#'
#' @return A ggplot object
#'
#' @examples

plotXval <- function(x, y, order="inverse") {

  # SET first year of plot as 1st of retro - 3
  y0 <- dims(x[[1]])$maxyear - length(y) - 2
  py <- do.call(seq, as.list(rev(dims(x[[1]])$maxyear - c(0, length(y)  - 2))))

  # CONVERT inputs to data.tables
  dato <- dto(x, y0)
  datp <- dtp(y, y0)

  # CALCULATE mase
  if(order == "inverse")
    idr <- 1
  else if (order == "ahead")
    idr <- length(y)
  else {
    idx <- an(names(y)) == dims(x[[1]])$maxyear
    if(sum(idx) == 1)
      idr <- which(idr)
    else
      stop("Could not identify reference run (to last year).")
  }

  # CALCULATE mase
  imase <- mase(x, y[-idr], order=order)

  # GENERATE facet labels
  lbs <- unlist(lapply(seq(length(imase)), function(x)
    paste(names(imase)[x], "\nMASE:", format(imase[x], digits=3))))
  names(lbs) <- names(imase)

  llb <- names(y)
  llb[idr] <- paste(llb[idr], "(ref)")
  # PLOT

  p <- ggplot(datp, aes(x=year, y=data, colour=final)) +

  # data lines and points
  geom_line(data=dato, linetype=2, colour="gray") +
  geom_point(data=dato, colour="black", size=3) +
  geom_point(data=dato, colour="white", size=2.6) +
  geom_point(data=dato[year %in% py,], aes(colour=ac(year-1)), size=2.6) +
  
  # retro lines and hindcast point
  geom_line() + geom_point(data=datp[year==pred, ]) +

  # format
  facet_wrap(~index, scales="free_y", ncol=2, labeller=as_labeller(lbs)) +
  xlab("") + ylab("") + scale_color_manual("", labels=rev(llb),
    values=rev(c("#000000", "#E69F00", "#56B4E9", "#009E73", "#D55E00",
    "#E69F00", "#56B4E9", "#009E73", "#D55E00", "#0072B2"))) +
  theme(legend.position="bottom")

  return(p)
}
# }}}

