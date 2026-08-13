export interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
  pending?: boolean;
}

export interface SuggestedPrompt {
  icon?: string;
  title: string;
  prompt: string;
}
