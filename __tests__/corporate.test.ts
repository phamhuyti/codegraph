/**
 * Corporate / restricted-network mode — npm OK, no phone-home.
 */

import { describe, it, expect, afterEach } from 'vitest';
import { isCorporateMode, resetCorporateModeCache } from '../src/corporate';
import { updateCheckDisabled } from '../src/upgrade/update-check';
import { shouldOfferBetaSignup } from '../src/installer/beta-signup';

describe('corporate mode', () => {
  afterEach(() => {
    resetCorporateModeCache();
  });

  it('CODEGRAPH_CORPORATE=1 forces corporate on', () => {
    expect(isCorporateMode({ CODEGRAPH_CORPORATE: '1' })).toBe(true);
  });

  it('CODEGRAPH_CORPORATE=0 forces corporate off even if package.json says otherwise', () => {
    expect(isCorporateMode({ CODEGRAPH_CORPORATE: '0' })).toBe(false);
  });

  it('disables update checks in corporate mode', () => {
    expect(updateCheckDisabled({ CODEGRAPH_CORPORATE: '1' })).toBe(true);
    expect(updateCheckDisabled({ CODEGRAPH_CORPORATE: '0' })).toBe(false);
  });

  it('never offers the beta waitlist in corporate mode', () => {
    expect(
      shouldOfferBetaSignup({
        dir: '/tmp/codegraph-corporate-beta-test',
        stdinIsTTY: true,
        stdoutIsTTY: true,
      }),
    ).toBe(false); // package.json corporate:true on this fork
  });
});
