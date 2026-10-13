"""Small causal temporal network. NumPy only; no image-classifier weights."""
import numpy as np

CLASSES = ['advance_warning', 'lift', 'brake', 'no_cue']
FEATURES = ['speed_kph_scaled', 'speed_present', 'speed_fresh', 'speed_age', 'speed_score',
            'distance_map', 'distance_present', 'geometry_fresh', 'geometry_age', 'geometry_score',
            'severity_straight', 'severity_gentle', 'severity_medium', 'severity_sharp', 'severity_uturn',
            'timing_none', 'timing_later', 'timing_soon', 'timing_now',
            'minimap_visible', 'minimap_fresh', 'minimap_age', 'minimap_score',
            'validity_pass', 'validity_fresh', 'validity_age']


def features(history):
    if len(history) != 20:
        raise ValueError('Expected exactly 20 causal history rows.')
    rows = []
    for index, row in enumerate(history):
        if index and abs(row['time'] - history[index - 1]['time'] - 0.1) > 1e-5:
            raise ValueError('History is not 10 Hz.')
        modules, ages = row['observations'], row['ages']
        for item in modules.values():
            if item['capturedAt'] > row['time'] + 1e-8 or item['completedAt'] > row['time'] + 1e-8:
                raise ValueError('Future information in history.')
        def value(name): return modules.get(name, {}).get('value') or {}
        def fresh(name): return float(modules.get(name, {}).get('state') == 'fresh')
        def age(name): return min(30., max(0., ages.get(name, 30.))) / 2
        def score(name): return modules.get(name, {}).get('confidence', 0.)
        speed = value('speed').get('number')
        if modules.get('speed', {}).get('units') != 'km/h':
            speed = None
        geometry = value('geometry'); distance = geometry.get('turnDistance')
        rows.append([0 if speed is None else speed / 500, float(speed is not None), fresh('speed'), age('speed'), score('speed'),
            0 if distance is None else distance, float(distance is not None), fresh('geometry'), age('geometry'), score('geometry'),
            *[float(geometry.get('severity') == item) for item in ['straight', 'gentle', 'medium', 'sharp', 'uTurn']],
            *[float(geometry.get('timing') == item) for item in ['none', 'later', 'soon', 'now']],
            float(value('minimap').get('flag') is True), fresh('minimap'), age('minimap'), score('minimap'),
            float(value('validity').get('flag') is True), fresh('validity'), age('validity')])
    result = np.asarray(rows, dtype=np.float32)
    if result.shape != (20, len(FEATURES)) or not np.isfinite(result).all():
        raise ValueError('Invalid feature shape or nonfinite measurements.')
    return result


class TemporalNetwork:
    """Left-padded 3-tap temporal convolution -> tanh -> mean pool -> softmax.

    Pooling includes only the 20 observed history rows, never post-decision frames.
    Raw outputs are uncalibrated class scores, not empirical accuracy estimates.
    """
    def __init__(self, seed=7, hidden=16):
        rng = np.random.default_rng(seed)
        self.params = {
            'kernel': rng.normal(0, .05, (3, len(FEATURES), hidden)).astype(np.float32),
            'bias': np.zeros(hidden, np.float32),
            'head': rng.normal(0, .05, (hidden, len(CLASSES))).astype(np.float32),
            'head_bias': np.zeros(len(CLASSES), np.float32)}

    def forward(self, x):
        padded = np.pad(x, ((0, 0), (2, 0), (0, 0)))
        windows = np.stack([padded[:, offset:offset+20] for offset in range(3)], axis=2)
        hidden = np.tanh(np.einsum('btkf,kfh->bth', windows, self.params['kernel']) + self.params['bias'])
        pooled = hidden.mean(axis=1)
        logits = pooled @ self.params['head'] + self.params['head_bias']
        logits -= logits.max(axis=1, keepdims=True)
        exp = np.exp(logits); probabilities = exp / exp.sum(axis=1, keepdims=True)
        return probabilities, (windows, hidden, pooled)

    def loss_gradients(self, x, y):
        probabilities, (windows, hidden, pooled) = self.forward(x)
        loss = -np.log(np.maximum(probabilities[np.arange(len(y)), y], 1e-8)).mean()
        dlogits = probabilities.copy(); dlogits[np.arange(len(y)), y] -= 1; dlogits /= len(y)
        dhidden = (dlogits @ self.params['head'].T)[:, None, :] / 20 * (1 - hidden**2)
        gradients = {'head': pooled.T @ dlogits, 'head_bias': dlogits.sum(axis=0),
                     'kernel': np.einsum('btkf,bth->kfh', windows, dhidden), 'bias': dhidden.sum(axis=(0, 1))}
        return float(loss), gradients

    def fit(self, x, y, epochs=300, learning_rate=.01):
        first = {key: np.zeros_like(value) for key, value in self.params.items()}
        second = {key: np.zeros_like(value) for key, value in self.params.items()}
        for step in range(1, epochs + 1):
            loss, gradients = self.loss_gradients(x, y)
            for key, gradient in gradients.items():
                first[key] = .9 * first[key] + .1 * gradient
                second[key] = .999 * second[key] + .001 * gradient**2
                self.params[key] -= learning_rate * (first[key] / (1 - .9**step)) / (np.sqrt(second[key] / (1 - .999**step)) + 1e-8)
        return loss
