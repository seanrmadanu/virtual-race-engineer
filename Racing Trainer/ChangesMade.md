### Dataset and Route-Tracing Approach

Earlier development introduced a minimap dataset recorder and dataset-audit system. The recorder can automatically save cropped Motorfest minimap frames while avoiding near-duplicate images.

A manual labeling workflow was planned for classifying these captured minimap images, but the full labeler was not completed.

During later experimentation, development shifted toward a real-time computer-vision approach. Instead of requiring labeled examples to recognize every route type, Racing Trainer now attempts to isolate the yellow GPS route directly from each minimap frame and displays the detected route using a magenta debug trace.

The current architecture therefore contains both systems:

- **Dataset tooling — experimental/supporting:** captures minimap examples that can later be used for testing, validation, failure analysis, or machine-learning experiments.
- **Real-time route tracing — primary approach:** extracts the GPS route directly from gameplay frames and will feed the upcoming route-geometry system.

The dataset system is currently retained as developer tooling but is not required for the live route-tracing pipeline.

############################################
Attempt 1
Dataset collection + planned classification
        ↓
Found scalability/manual-labeling problem
        ↓
Changed architecture
        ↓
Real-time computer vision route extraction
        ↓
Kept dataset tools for validation/testing

