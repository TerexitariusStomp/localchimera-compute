import { z } from 'zod';

/**
 * Key health status for key pool
 */
export const KeyHealthStatus = z.enum([
  'healthy',
  'degraded',
  'failed',
  'rate_limited',
  'depleted'
]);

export type KeyHealthStatus = z.infer<typeof KeyHealthStatus>;

/**
 * Health report to key pool
 */
export const HealthReportSchema = z.object({
  key: z.string(),
  status: KeyHealthStatus,
  error: z.string().nullable().optional(),
  cost: z.number().nullable().optional()
});

export type HealthReport = z.infer<typeof HealthReportSchema>;

/**
 * Key pool response when requesting a key
 */
export const KeyResponseSchema = z.object({
  success: z.boolean(),
  model: z.string(),
  key: z.string(),
  pool: z.object({
    totalKeys: z.number(),
    healthyKeys: z.number()
  })
});

export type KeyResponse = z.infer<typeof KeyResponseSchema>;
