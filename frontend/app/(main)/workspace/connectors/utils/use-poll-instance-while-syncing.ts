'use client';

import { useEffect } from 'react';
import { CONNECTOR_INSTANCE_STATUS } from '../constants';
import { refreshConnectorInstanceDetails } from './refresh-instance-details';

// A queued sync usually starts within seconds, so poll often at first and back off to once a minute.
const FIRST_POLL_MS = 5_000;
const MAX_POLL_MS = 60_000;

function isSyncInProgressStatus(status?: string | null): boolean {
  const normalized = (status ?? CONNECTOR_INSTANCE_STATUS.IDLE).toUpperCase();
  return (
    normalized === CONNECTOR_INSTANCE_STATUS.SYNCING ||
    normalized === CONNECTOR_INSTANCE_STATUS.FULL_SYNCING ||
    // Queued too, or the card would never notice the sync actually starting.
    normalized === CONNECTOR_INSTANCE_STATUS.QUEUED ||
    // Purge clears indexes asynchronously; poll so the card leaves "Purging data".
    normalized === CONNECTOR_INSTANCE_STATUS.PURGING
  );
}

/** Refetch one instance while status is QUEUED / SYNCING / FULL_SYNCING / PURGING: after 5 s, doubling up to every minute. */
export function usePollInstanceWhileSyncing(
  connectorId: string | undefined,
  status?: string | null
): void {
  useEffect(() => {
    if (!connectorId || !isSyncInProgressStatus(status)) {
      return;
    }

    let delay = FIRST_POLL_MS;
    let timeoutId: number;
    const poll = () => {
      void refreshConnectorInstanceDetails(connectorId).catch(() => {});
      delay = Math.min(delay * 2, MAX_POLL_MS);
      timeoutId = window.setTimeout(poll, delay);
    };
    timeoutId = window.setTimeout(poll, delay);

    return () => {
      window.clearTimeout(timeoutId);
    };
  }, [connectorId, status]);
}
