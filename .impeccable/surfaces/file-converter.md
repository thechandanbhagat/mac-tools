# File Converter
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: Export selected images or PDFs to new files with clear options and visible consequences.
OWN-WORLD: Inherit the shared header, native segmented picker, flat file rows, system controls, contextual help, and fixed footer.
STORY: Choose a conversion; add files; adjust settings or PDF order; choose output folder; convert; inspect exports and issues.
FIRST VIEWPORT: Title/help, Images / Combine PDFs / Compress PDFs, relevant settings, input list, output location, and Convert.
FORM: A single focused export surface without redundant labels or another review sheet for original-preserving output.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Constraints
Image exports support JPEG, PNG, and TIFF, optional resize, and applicable quality controls. Apply orientation, remove metadata, and flatten JPEG transparency onto white. Combine PDFs in the displayed order with accessible earlier/later controls.

PDF compression rasterizes pages. Keep the loss of searchable text, links, forms, and annotations visible before conversion; help cannot replace this consequence. Compression may increase file size, so report actual output sizes. Keep originals and never overwrite existing destination files. Preserve completed exports on cancellation and report per-file failures or limits. Demo conversion uses its disposable sample output folder. Unsupported inputs and scope details belong in contextual help, with actionable errors visible.

## Source and evidence
`FileConverterView.swift`, `FileConverterModel.swift`, and `Core/FileConverter.swift` define behavior. This brief records source scope; runtime and visual evidence is tracked separately under `.impeccable/review`.
