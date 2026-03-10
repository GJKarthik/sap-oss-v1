// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import type { Meta, StoryObj } from '@storybook/angular';
import { moduleMetadata } from '@storybook/angular';
import { GenUiOutletComponent } from './genui-outlet.component';
import { GenUiRendererModule } from '../genui-renderer.module';
import { A2UI_SCHEMA_VERSION } from '../renderer/dynamic-renderer.service';

const meta: Meta<GenUiOutletComponent> = {
  title: 'GenUI Renderer / GenUiOutlet',
  component: GenUiOutletComponent,
  decorators: [
    moduleMetadata({
      imports: [GenUiRendererModule],
    }),
  ],
  parameters: {
    docs: {
      description: {
        component:
          'Dynamic outlet that renders agent-generated A2UI schemas into ' +
          'live UI5 Web Components Angular trees. Schemas are validated ' +
          'against the security allowlist before rendering.',
      },
    },
  },
};

export default meta;
type Story = StoryObj<GenUiOutletComponent>;

// ---------------------------------------------------------------------------
// Button schema
// ---------------------------------------------------------------------------
export const SingleButton: Story = {
  args: {
    schema: {
      component: 'ui5-button',
      schemaVersion: A2UI_SCHEMA_VERSION,
      props: { text: 'Click me', design: 'Emphasized' },
    },
  },
};

// ---------------------------------------------------------------------------
// Form floorplan
// ---------------------------------------------------------------------------
export const FormFloorplan: Story = {
  args: {
    schema: {
      component: 'ui5-form',
      schemaVersion: A2UI_SCHEMA_VERSION,
      props: { headerText: 'New Employee' },
      children: [
        {
          component: 'ui5-form-group',
          props: { headerText: 'Personal Data' },
          children: [
            {
              component: 'ui5-form-item',
              children: [
                { component: 'ui5-label', props: { text: 'First Name', required: true } },
                { component: 'ui5-input', props: { placeholder: 'Enter first name' } },
              ],
            },
            {
              component: 'ui5-form-item',
              children: [
                { component: 'ui5-label', props: { text: 'Last Name', required: true } },
                { component: 'ui5-input', props: { placeholder: 'Enter last name' } },
              ],
            },
          ],
        },
      ],
    },
  },
};

// ---------------------------------------------------------------------------
// Table schema
// ---------------------------------------------------------------------------
export const DataTable: Story = {
  args: {
    schema: {
      component: 'ui5-table',
      schemaVersion: A2UI_SCHEMA_VERSION,
      props: { noDataText: 'No data available' },
      slots: {
        columns: [
          { component: 'ui5-table-column', props: { slot: 'columns' }, children: [
            { component: 'ui5-label', props: { text: 'Name' } },
          ]},
          { component: 'ui5-table-column', props: { slot: 'columns' }, children: [
            { component: 'ui5-label', props: { text: 'Status' } },
          ]},
        ],
      },
      children: [
        {
          component: 'ui5-table-row',
          children: [
            { component: 'ui5-table-cell', children: [{ component: 'ui5-label', props: { text: 'Alice' } }] },
            { component: 'ui5-table-cell', children: [{ component: 'ui5-label', props: { text: 'Active' } }] },
          ],
        },
      ],
    },
  },
};

// ---------------------------------------------------------------------------
// Null schema (no-op render)
// ---------------------------------------------------------------------------
export const NoSchema: Story = {
  args: {
    schema: null,
  },
};
