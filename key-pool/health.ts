import { getPoolStatus } from './manager';

export interface ServiceHealth {
  status: 'ok' | 'degraded' | 'down';
  message?: string;
  details?: any;
}

/**
 * Get key pool health status
 */
export function getKeyPoolHealth(): ServiceHealth {
  try {
    const poolStatus = getPoolStatus();

    const healthyKeys = poolStatus.health.healthy;
    const totalKeys = poolStatus.totalKeys;

    const healthPercentage = totalKeys > 0
      ? (healthyKeys / totalKeys) * 100
      : 0;

    let status: 'ok' | 'degraded' | 'down' = 'ok';
    if (healthPercentage < 50) {
      status = 'degraded';
    }
    if (healthyKeys === 0) {
      status = 'down';
    }

    return {
      status,
      details: {
        totalKeys,
        healthyKeys,
        healthPercentage: healthPercentage.toFixed(2) + '%',
        health: poolStatus.health,
        stats: poolStatus.stats
      }
    };
  } catch {
    return {
      status: 'down',
      message: 'Key pool service unavailable'
    };
  }
}
