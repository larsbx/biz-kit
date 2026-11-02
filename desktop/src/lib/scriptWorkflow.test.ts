import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { invoke } from '@tauri-apps/api/core';
import Scripts from './panels/Scripts.svelte';
import Confirm from './Confirm.svelte';
import { pending } from './confirmation.svelte';

vi.mock('@tauri-apps/api/core', () => ({ invoke: vi.fn(), Channel: vi.fn() }));
const script = { path: "/fixture/it's a script.sh", name: "it's a script.sh", summary: 'fixture', hasApply: true, interpreter: 'bash' };
const info = { hosts: [], scriptsDir: '/fixture', configPath: '/config.json' };
beforeEach(() => {
  pending.ask = null;
  vi.mocked(invoke).mockImplementation(async cmd => cmd === 'list_scripts' ? [script] : undefined);
});
afterEach(() => { pending.ask = null; cleanup(); vi.resetAllMocks(); });

it('passes --dry-run explicitly instead of relying on script defaults', async () => {
  render(Scripts, { info });
  await fireEvent.click(await screen.findByRole('button', { name: 'Dry run' }));
  const args = vi.mocked(invoke).mock.calls.find(([cmd]) => cmd === 'run_script')?.[1] as { path: string; args: string[] };
  expect(args.path).toBe(script.path);
  expect(args.args).toEqual(['--dry-run']);
});

it('reviews exact apply arguments and does not run when confirmation is cancelled', async () => {
  render(Scripts, { info });
  render(Confirm);
  await fireEvent.click(await screen.findByRole('button', { name: /^Apply$/ }));
  expect(pending.ask?.command).toBe(JSON.stringify(['bash', script.path, '--apply']));
  expect(vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === 'run_script')).toBe(false);
  await fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === 'run_script')).toBe(false);
});

it('requires confirmation for an ordinary script with no dry-run contract', async () => {
  vi.mocked(invoke).mockImplementation(async cmd => cmd === 'list_scripts' ? [{ ...script, hasApply: false }] : undefined);
  render(Scripts, { info });
  render(Confirm);
  await fireEvent.click(await screen.findByRole('button', { name: /^Run$/ }));
  expect(vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === 'run_script')).toBe(false);
  expect(pending.ask?.command).toBe(JSON.stringify(['bash', script.path]));
  await fireEvent.click(screen.getAllByRole('button', { name: /^Run$/ }).at(-1)!);
  await vi.waitFor(() => expect(vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === 'run_script')).toBe(true));
  const args = vi.mocked(invoke).mock.calls.find(([cmd]) => cmd === 'run_script')?.[1] as { args: string[] };
  expect(args.args).toEqual([]);
});
