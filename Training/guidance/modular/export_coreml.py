"""Export a reviewed structured model; save only after NumPy/Torch/Core ML parity.

Optional macOS dependencies: torch and coremltools. This does not enable live cues.
Reference: https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html
"""
import argparse
import json
from pathlib import Path
import numpy as np
from temporal import FEATURES, CLASSES, TemporalNetwork


def export(directory, destination):
    card = json.loads((directory / 'model.json').read_text())
    if card['schema'] != 'structured-slowdown-v1' or card['features'] != FEATURES or card['classes'] != CLASSES or card['liveEnabled']:
        raise ValueError('Unsupported or nonexperimental model artifact.')
    if destination.exists() or destination.suffix != '.mlpackage':
        raise ValueError('Choose a new .mlpackage destination.')
    try:
        import torch
        import coremltools as ct
    except ImportError as error:
        raise RuntimeError('Core ML export needs torch and coremltools in a dedicated environment. No export was performed.') from error
    weights = dict(np.load(directory / 'weights.npz', allow_pickle=False))
    class Network(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.conv = torch.nn.Conv1d(len(FEATURES), len(weights['bias']), 3)
            self.head = torch.nn.Linear(len(weights['bias']), len(CLASSES))
            with torch.no_grad():
                self.conv.weight.copy_(torch.from_numpy(weights['kernel'].transpose(2, 1, 0)))
                self.conv.bias.copy_(torch.from_numpy(weights['bias']))
                self.head.weight.copy_(torch.from_numpy(weights['head'].T))
                self.head.bias.copy_(torch.from_numpy(weights['head_bias']))
        def forward(self, history):
            padded = torch.nn.functional.pad(history.transpose(1, 2), (2, 0))
            return torch.softmax(self.head(torch.tanh(self.conv(padded)).mean(dim=2)), dim=1)
    model = Network().eval()
    samples = np.load(directory / 'parity_inputs.npz', allow_pickle=False)['x']
    if len(samples) == 0:
        raise ValueError('Reviewed validation examples required for parity.')
    reference = TemporalNetwork(); reference.params = weights
    traced = torch.jit.trace(model, torch.from_numpy(samples[:1]))
    converted = ct.convert(traced, inputs=[ct.TensorType(name='history', shape=(1, 20, len(FEATURES)))],
        outputs=[ct.TensorType(name='probabilities')], convert_to='mlprogram', compute_precision=ct.precision.FLOAT32)
    max_error = 0.
    for sample in samples:
        x = sample[None].astype(np.float32)
        expected = reference.forward(x)[0]
        with torch.no_grad(): torch_value = model(torch.from_numpy(x)).numpy()
        actual = np.asarray(converted.predict({'history': x})['probabilities'])
        np.testing.assert_allclose(torch_value, expected, rtol=1e-4, atol=1e-5)
        np.testing.assert_allclose(actual, expected, rtol=1e-4, atol=1e-5)
        if actual.argmax() != expected.argmax(): raise ValueError('Core ML changed the predicted class.')
        max_error = max(max_error, float(np.max(np.abs(actual - expected))))
    converted.user_defined_metadata['status'] = 'experimental_shadow_only'
    converted.user_defined_metadata['features'] = json.dumps(FEATURES)
    converted.user_defined_metadata['classes'] = json.dumps(CLASSES)
    converted.save(str(destination))
    report = {'passed': True, 'samples': len(samples), 'maximumAbsoluteError': max_error, 'liveEnabled': False}
    with destination.with_suffix('.parity.json').open('x') as stream: json.dump(report, stream, indent=2)
    print(json.dumps(report))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('model_directory', type=Path); parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    export(args.model_directory, args.destination)
