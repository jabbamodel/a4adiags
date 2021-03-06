% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/xval.R
\name{mase}
\alias{mase}
\title{Compute mean absolute scaled error (MASE)}
\usage{
mase(ref, preds, ...)
}
\arguments{
\item{ref}{Reference or naive prediction.}

\item{preds}{Predicitions to compare to reference.}

\item{order}{Are predictions in 'inverse' (default) or 'ahead' order.}
}
\value{
A numeric vector of the same length as 'preds'.
}
\description{
Franses, PH. "A note on the Mean Absolute Scaled Error". International Journal of Forecasting. 32 (1): 20–22. doi:10.1016/j.ijforecast.2015.03.008.
}
