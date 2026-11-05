# Archived dataset UI

These unused views were removed from the app target on October 15, 2026.
`LegacyDatasetMetadataCounterView` had no callers; it was the only launcher
for the old `DatasetLabelerView`. The current route-mask editor remains available
through Input Diagnostics → Datasets. `DatasetMetadataStore` and saved data
remain in place for compatibility. The `.disabled` files preserve the prior UI
for reference without compiling it into the app.
