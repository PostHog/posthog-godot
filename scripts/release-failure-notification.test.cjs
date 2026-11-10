const test = require('node:test');
const assert = require('node:assert/strict');
const releaseFailureNotification = require('./release-failure-notification.cjs');

const publishName = 'Commit and publish approved release';
const resultName = 'Notify Slack/PostHog - Release Result';

const job = (name, conclusion, steps = [{ name: 'Set up job', conclusion: 'success' }]) => ({
    name,
    conclusion,
    steps,
    html_url: `https://github.com/PostHog/posthog-godot/actions/runs/1/job/${name.length}`,
});

const step = (name, conclusion) => ({ name, conclusion });

async function run({ conclusion, jobs }) {
    const github = {
        paginate: async () => jobs,
        rest: { actions: { listJobsForWorkflowRunAttempt: () => {} } },
    };
    const context = {
        repo: { owner: 'PostHog', repo: 'posthog-godot' },
        payload: {
            workflow_run: {
                id: 1,
                run_attempt: 1,
                conclusion,
                html_url: 'https://github.com/PostHog/posthog-godot/actions/runs/1',
            },
        },
    };
    return releaseFailureNotification({ github, context, channel: 'C123' });
}

test('stays quiet when the run succeeded', async () => {
    const result = await run({
        conclusion: 'success',
        jobs: [
            job(publishName, 'success'),
            job(resultName, 'success', [step('Notify Slack - Released', 'success')]),
        ],
    });
    assert.equal(result, null);
});

test('alerts when a job failed', async () => {
    const result = await run({
        conclusion: 'failure',
        jobs: [job(publishName, 'failure'), job(resultName, 'success')],
    });
    assert.equal(result.channel, 'C123');
    assert.match(result.text, /Release process failed or was cancelled/);
    assert.match(result.text, new RegExp(`\\|${publishName}>: failure`));
});

test('stays quiet when the approval was rejected and the reply was delivered', async () => {
    const result = await run({
        conclusion: 'failure',
        jobs: [
            job(publishName, 'failure', []),
            job(resultName, 'success', [step('Notify Slack - Rejected', 'success')]),
        ],
    });
    assert.equal(result, null);
});

test('stays quiet for a cancelled run with no jobs', async () => {
    const result = await run({ conclusion: 'cancelled', jobs: [] });
    assert.equal(result, null);
});

test('alerts when the release exists but the released notice was skipped', async () => {
    const result = await run({
        conclusion: 'success',
        jobs: [job(publishName, 'success'), job(resultName, 'success', [step('Notify Slack - Released', 'skipped')])],
    });
    assert.match(result.text, /GitHub release published; follow-up problems/);
    assert.match(result.text, /released Slack notification did not run/);
});
