// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import type { Meta, StoryObj } from '@storybook/angular';
import { moduleMetadata } from '@storybook/angular';
import { JouleChatComponent } from './joule-chat.component';
import { AgUiModule } from '../ag-ui.module';

const meta: Meta<JouleChatComponent> = {
  title: 'AG-UI / JouleChat',
  component: JouleChatComponent,
  decorators: [
    moduleMetadata({
      imports: [AgUiModule],
    }),
  ],
  parameters: {
    docs: {
      description: {
        component:
          'SAP Fiori Joule-style chat shell that bridges the AG-UI SSE/WS ' +
          'transport with a streaming UI5 Web Components chat interface.',
      },
    },
  },
  argTypes: {
    transport: { control: { type: 'radio' }, options: ['sse', 'websocket'] },
    securityClass: {
      control: { type: 'select' },
      options: ['public', 'internal', 'confidential', 'restricted'],
    },
    showRouteBadge: { control: 'boolean' },
    autoConnect: { control: 'boolean' },
  },
};

export default meta;
type Story = StoryObj<JouleChatComponent>;

// ---------------------------------------------------------------------------
// Default — disconnected, no auto-connect (safe for static docs/snapshots)
// ---------------------------------------------------------------------------
export const Default: Story = {
  args: {
    endpoint: '/ag-ui/run',
    transport: 'sse',
    title: 'Joule',
    placeholder: 'Ask me anything...',
    showRouteBadge: false,
    autoConnect: false,
    securityClass: 'internal',
  },
};

// ---------------------------------------------------------------------------
// With route badge visible
// ---------------------------------------------------------------------------
export const WithRouteBadge: Story = {
  args: {
    ...Default.args,
    title: 'Joule (AI Core)',
    showRouteBadge: true,
  },
};

// ---------------------------------------------------------------------------
// WebSocket transport variant
// ---------------------------------------------------------------------------
export const WebSocketTransport: Story = {
  args: {
    ...Default.args,
    transport: 'websocket',
    endpoint: 'ws://localhost:9140/ag-ui/ws',
    title: 'Joule (WebSocket)',
  },
};

// ---------------------------------------------------------------------------
// Security class: confidential
// ---------------------------------------------------------------------------
export const ConfidentialData: Story = {
  args: {
    ...Default.args,
    securityClass: 'confidential',
    title: 'Joule (Confidential)',
    showRouteBadge: true,
  },
};
