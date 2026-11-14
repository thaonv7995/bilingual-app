import test from 'node:test';
import assert from 'node:assert/strict';

import {
  DEFAULT_APP_FEATURES,
  parseFeatureFlagEnv,
  resolveAppFeatures,
} from '../src/lib/featureConfig.ts';

test('audiobook feature defaults to disabled on client fallback', () => {
  assert.equal(DEFAULT_APP_FEATURES.audiobookEnabled, false);
  assert.deepEqual(resolveAppFeatures(undefined), { audiobookEnabled: false });
  assert.deepEqual(resolveAppFeatures(null), { audiobookEnabled: false });
  assert.deepEqual(resolveAppFeatures({ features: {} }), { audiobookEnabled: false });
});

test('parseFeatureFlagEnv parses standard truthy/falsy values with fallback', () => {
  assert.equal(parseFeatureFlagEnv('true', false), true);
  assert.equal(parseFeatureFlagEnv('1', false), true);
  assert.equal(parseFeatureFlagEnv('YES', false), true);
  assert.equal(parseFeatureFlagEnv('false', true), false);
  assert.equal(parseFeatureFlagEnv('0', true), false);
  assert.equal(parseFeatureFlagEnv('off', true), false);
  assert.equal(parseFeatureFlagEnv('', false), false);
  assert.equal(parseFeatureFlagEnv(undefined, false), false);
  assert.equal(parseFeatureFlagEnv('invalid', true), true);
});

test('resolveAppFeatures lets backend /api/config override client default', () => {
  assert.deepEqual(
    resolveAppFeatures({ features: { audiobookEnabled: true } }, { audiobookEnabled: false }),
    { audiobookEnabled: true },
  );
  assert.deepEqual(
    resolveAppFeatures({ features: { audiobookEnabled: false } }, { audiobookEnabled: true }),
    { audiobookEnabled: false },
  );
});

