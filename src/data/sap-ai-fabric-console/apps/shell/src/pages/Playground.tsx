import { useState, useRef, useEffect } from 'react';
import './Playground.css';

interface Message {
  id: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: Date;
  tokens?: number;
  latency?: number;
}

interface ModelConfig {
  model: string;
  temperature: number;
  maxTokens: number;
  topP: number;
  systemPrompt: string;
}

const defaultConfig: ModelConfig = {
  model: 'gpt-4o',
  temperature: 0.7,
  maxTokens: 4096,
  topP: 1.0,
  systemPrompt: 'You are a helpful AI assistant.',
};

const models = ['gpt-4o', 'gpt-4o-mini', 'gpt-4-turbo', 'claude-3-opus', 'claude-3-sonnet'];

export function PlaygroundPage() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [config, setConfig] = useState<ModelConfig>(defaultConfig);
  const [showConfig, setShowConfig] = useState(true);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  useEffect(() => {
    scrollToBottom();
  }, [messages]);

  const sendMessage = async () => {
    if (!input.trim() || isLoading) return;

    const userMessage: Message = {
      id: `msg-${Date.now()}`,
      role: 'user',
      content: input.trim(),
      timestamp: new Date(),
    };

    setMessages(prev => [...prev, userMessage]);
    setInput('');
    setIsLoading(true);

    // Simulate API call
    const startTime = Date.now();
    await new Promise(resolve => setTimeout(resolve, 1000 + Math.random() * 2000));

    const assistantMessage: Message = {
      id: `msg-${Date.now()}`,
      role: 'assistant',
      content: generateMockResponse(input.trim()),
      timestamp: new Date(),
      tokens: Math.floor(Math.random() * 500) + 100,
      latency: Date.now() - startTime,
    };

    setMessages(prev => [...prev, assistantMessage]);
    setIsLoading(false);
  };

  const generateMockResponse = (query: string): string => {
    const responses = [
      `I understand you're asking about "${query}". This is a mock response from the playground. In production, this would connect to your SAP AI Core streaming endpoint.`,
      `Great question! "${query}" is an interesting topic. The playground allows you to test different models and parameters before deploying to production.`,
      `Based on your query "${query}", I can provide insights. This playground supports multiple models including GPT-4o, Claude, and custom fine-tuned models.`,
    ];
    return responses[Math.floor(Math.random() * responses.length)];
  };

  const clearChat = () => {
    setMessages([]);
  };

  const handleKeyPress = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  };

  const totalTokens = messages.reduce((sum, m) => sum + (m.tokens || 0), 0);

  return (
    <div className="playground-page">
      <div className="playground-header">
        <h2>Prompt Playground</h2>
        <div className="header-actions">
          <button className="btn-outline" onClick={() => setShowConfig(!showConfig)}>
            {showConfig ? '← Hide Config' : '⚙ Show Config'}
          </button>
          <button className="btn-outline" onClick={clearChat}>
            🗑 Clear Chat
          </button>
        </div>
      </div>

      <div className="playground-container">
        {/* Chat Area */}
        <div className="chat-area">
          <div className="messages-container">
            {messages.length === 0 && (
              <div className="empty-state">
                <div className="empty-icon">🎮</div>
                <h3>Welcome to the Prompt Playground</h3>
                <p>Test your prompts with different models and configurations.</p>
                <div className="quick-prompts">
                  <button onClick={() => setInput('Explain SAP AI Core in simple terms')}>
                    Explain SAP AI Core
                  </button>
                  <button onClick={() => setInput('Write a Python function to connect to HANA')}>
                    HANA Python Example
                  </button>
                  <button onClick={() => setInput('What are the benefits of using RAG?')}>
                    RAG Benefits
                  </button>
                </div>
              </div>
            )}
            
            {messages.map((message) => (
              <div key={message.id} className={`message ${message.role}`}>
                <div className="message-avatar">
                  {message.role === 'user' ? '👤' : '🤖'}
                </div>
                <div className="message-content">
                  <div className="message-text">{message.content}</div>
                  <div className="message-meta">
                    {message.tokens && <span>{message.tokens} tokens</span>}
                    {message.latency && <span>{message.latency}ms</span>}
                    <span>{message.timestamp.toLocaleTimeString()}</span>
                  </div>
                </div>
              </div>
            ))}
            
            {isLoading && (
              <div className="message assistant">
                <div className="message-avatar">🤖</div>
                <div className="message-content">
                  <div className="typing-indicator">
                    <span></span><span></span><span></span>
                  </div>
                </div>
              </div>
            )}
            <div ref={messagesEndRef} />
          </div>

          <div className="input-area">
            <div className="input-stats">
              <span>Model: {config.model}</span>
              <span>Total tokens: {totalTokens}</span>
            </div>
            <div className="input-container">
              <textarea
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyPress={handleKeyPress}
                placeholder="Type your message... (Enter to send, Shift+Enter for new line)"
                rows={3}
                disabled={isLoading}
              />
              <button 
                className="send-btn" 
                onClick={sendMessage}
                disabled={!input.trim() || isLoading}
              >
                {isLoading ? '...' : '➤'}
              </button>
            </div>
          </div>
        </div>

        {/* Config Panel */}
        {showConfig && (
          <div className="config-panel">
            <h3>Configuration</h3>
            
            <div className="config-section">
              <label>Model</label>
              <select 
                value={config.model}
                onChange={(e) => setConfig(prev => ({ ...prev, model: e.target.value }))}
              >
                {models.map(m => <option key={m} value={m}>{m}</option>)}
              </select>
            </div>

            <div className="config-section">
              <label>Temperature: {config.temperature}</label>
              <input 
                type="range"
                min="0"
                max="2"
                step="0.1"
                value={config.temperature}
                onChange={(e) => setConfig(prev => ({ ...prev, temperature: parseFloat(e.target.value) }))}
              />
              <div className="range-labels">
                <span>Precise</span>
                <span>Creative</span>
              </div>
            </div>

            <div className="config-section">
              <label>Max Tokens: {config.maxTokens}</label>
              <input 
                type="range"
                min="256"
                max="8192"
                step="256"
                value={config.maxTokens}
                onChange={(e) => setConfig(prev => ({ ...prev, maxTokens: parseInt(e.target.value) }))}
              />
            </div>

            <div className="config-section">
              <label>Top P: {config.topP}</label>
              <input 
                type="range"
                min="0"
                max="1"
                step="0.1"
                value={config.topP}
                onChange={(e) => setConfig(prev => ({ ...prev, topP: parseFloat(e.target.value) }))}
              />
            </div>

            <div className="config-section">
              <label>System Prompt</label>
              <textarea
                value={config.systemPrompt}
                onChange={(e) => setConfig(prev => ({ ...prev, systemPrompt: e.target.value }))}
                rows={4}
                placeholder="Enter system prompt..."
              />
            </div>

            <div className="config-actions">
              <button className="btn-outline" onClick={() => setConfig(defaultConfig)}>
                Reset to Default
              </button>
            </div>

            <div className="config-presets">
              <h4>Presets</h4>
              <button onClick={() => setConfig({ ...defaultConfig, temperature: 0.2, systemPrompt: 'You are a precise code assistant.' })}>
                💻 Code Assistant
              </button>
              <button onClick={() => setConfig({ ...defaultConfig, temperature: 0.9, systemPrompt: 'You are a creative writing assistant.' })}>
                ✍️ Creative Writer
              </button>
              <button onClick={() => setConfig({ ...defaultConfig, model: 'gpt-4o-mini', maxTokens: 2048, systemPrompt: 'You are a concise summarizer.' })}>
                📝 Summarizer
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}