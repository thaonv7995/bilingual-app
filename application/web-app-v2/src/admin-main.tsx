import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { AdminApp } from '@/features/admin/AdminApp';
import '@/styles/fonts';
import '@/styles/tokens.css';
import '@/styles/reset.css';

const rootEl = document.getElementById('root');
if (!rootEl) throw new Error('#root not found');

createRoot(rootEl).render(
  <StrictMode>
    <AdminApp />
  </StrictMode>,
);
