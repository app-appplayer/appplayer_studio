/// Hosts built on this library (Studio, Studio Pro, Workbench) run host
/// extension apps (`manifest.type: extension`, platform spec 06 ④) as well
/// as applications — the one place they say so, e.g. to the market.
library;

const bool kRunsHostExtensions = true;
