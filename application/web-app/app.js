// app.js - Preact Single Page Application for Bilingual Book Reader

import { h, render } from './libs/preact.mjs';
import { useState, useEffect, useRef, useMemo } from './libs/hooks.mjs';
import htm from './libs/htm.mjs';
import {
  configureVocaClient,
  defaultVocaSettings,
  cleanWord,
  lookupWord,
  addWordToVoca,
  showVocaLookupResults,
  showVocaNotFoundPanel,
  removeVocaLookupPanel,
  getVocaLookupPanelCss,
  showVocaError,
} from './voca-client.js';

// Initialize htm with Preact
const html = htm.bind(h);

// Default settings configuration
const DEFAULT_SETTINGS = {
  provider: 'openai',
  baseURL: 'https://api.openai.com/v1',
  apiKey: '',
  model: 'gpt-4o-mini',
  realtimeApiKey: '',
  realtimeModel: 'gpt-realtime-mini',
  realtimeVoice: 'alloy',
  ...defaultVocaSettings(),
};

const HIGHLIGHT_COLORS = [
  { id: 'yellow', value: '#fde68a', label: 'Vàng' },
  { id: 'blue', value: '#93c5fd', label: 'Xanh' },
  { id: 'pink', value: '#f9a8d4', label: 'Hồng' },
  { id: 'green', value: '#86efac', label: 'Xanh lá' },
];

const PARAGRAPH_SELECTOR =
  'p, .chapter-start, .no-indent, h1, h2, h3, h4, h5, h6, li, blockquote, .section-title, .action-header, .action-title';

let highlightAppContext = null;

function getSavedProgress(slug) {
  try {
    const saved = localStorage.getItem(`bilingual.reader.progress.${slug}`);
    if (saved) return JSON.parse(saved);
  } catch (e) {}
  return null;
}

function getRelativeTime(timestamp) {
  const now = Date.now();
  const diffMs = now - timestamp;
  const diffMins = Math.floor(diffMs / 60000);
  if (diffMins < 1) return 'Vừa xong';
  if (diffMins < 60) return `${diffMins} phút trước`;
  const diffHours = Math.floor(diffMins / 60);
  if (diffHours < 24) return `${diffHours} giờ trước`;
  const diffDays = Math.floor(diffHours / 24);
  if (diffDays < 30) return `${diffDays} ngày trước`;
  const diffMonths = Math.floor(diffDays / 30);
  return `${diffMonths} tháng trước`;
}

function generateHighlightId() {
  return `hl-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 9)}`;
}

function loadHighlights(slug) {
  try {
    const saved = localStorage.getItem(`bilingual.reader.highlights.${slug}`);
    if (saved) {
      const parsed = JSON.parse(saved);
      return parsed.highlights || [];
    }
  } catch (e) {}
  return [];
}

function saveHighlights(slug, highlights) {
  localStorage.setItem(`bilingual.reader.highlights.${slug}`, JSON.stringify({ highlights }));
}

function getInitialRoute() {
  const hash = window.location.hash;
  if (!hash) return { book: null, page: 1, viewMode: null };
  const readMatch = hash.match(/^#\/read\/([^/]+)(?:\/page\/(\d+))?$/);
  if (readMatch) {
    const slug = readMatch[1];
    const savedProgress = getSavedProgress(slug);
    const pageNum = readMatch[2]
      ? parseInt(readMatch[2], 10)
      : (savedProgress?.page || 1);
    return {
      book: { slug },
      page: pageNum,
      viewMode: savedProgress?.viewMode || null,
    };
  }
  return { book: null, page: 1, viewMode: null };
}

const ACCESS_TOKEN_KEY = 'bilingual.reader.token';
const REFRESH_TOKEN_KEY = 'bilingual.reader.refreshToken';

function normalizeApiUrl(url) {
  if (/^https?:\/\//i.test(url)) return url;
  return url.startsWith('/') ? url : `/${url}`;
}

function persistAuthTokens(data, setTokenFn) {
  if (data.access_token) {
    localStorage.setItem(ACCESS_TOKEN_KEY, data.access_token);
    if (setTokenFn) setTokenFn(data.access_token);
  }
  if (data.refresh_token) {
    localStorage.setItem(REFRESH_TOKEN_KEY, data.refresh_token);
  }
  if (data.username) {
    localStorage.setItem('bilingual.reader.username', data.username);
  }
  if (data.is_admin !== undefined) {
    localStorage.setItem('bilingual.reader.isAdmin', data.is_admin);
    if (data.is_admin && data.access_token) {
      localStorage.setItem('bilingual.admin.token', data.access_token);
    } else {
      localStorage.removeItem('bilingual.admin.token');
    }
  }
}

function clearAuthSession(setTokenFn) {
  if (setTokenFn) setTokenFn('');
  localStorage.removeItem(ACCESS_TOKEN_KEY);
  localStorage.removeItem(REFRESH_TOKEN_KEY);
  localStorage.removeItem('bilingual.reader.isAdmin');
  localStorage.removeItem('bilingual.reader.username');
  localStorage.removeItem('bilingual.admin.token');
}

async function refreshAccessToken() {
  const storedRefresh = localStorage.getItem(REFRESH_TOKEN_KEY) || '';
  const refreshOptions = {
    method: 'POST',
    credentials: 'include',
  };
  if (storedRefresh) {
    refreshOptions.headers = { 'Content-Type': 'application/json' };
    refreshOptions.body = JSON.stringify({ refresh_token: storedRefresh });
  }

  const refreshRes = await fetch('/api/auth/refresh', refreshOptions);
  if (!refreshRes.ok) return null;

  const data = await refreshRes.json();
  if (!data.access_token) return null;

  localStorage.setItem(ACCESS_TOKEN_KEY, data.access_token);
  if (data.refresh_token) {
    localStorage.setItem(REFRESH_TOKEN_KEY, data.refresh_token);
  }
  if (localStorage.getItem('bilingual.reader.isAdmin') === 'true') {
    localStorage.setItem('bilingual.admin.token', data.access_token);
  }
  return data.access_token;
}

const colorMap = {
  yellow: '#fde68a',
  blue: '#93c5fd',
  pink: '#f9a8d4',
  green: '#86efac'
};

const webToolDefinitions = [
  {
    type: 'function',
    function: {
      name: 'highlight_text',
      description: 'Highlight a word or phrase on the current page with a color. Use when the user asks to mark, highlight, or annotate text.',
      parameters: {
        type: 'object',
        properties: {
          text: {
            type: 'string',
            description: 'The exact word or phrase to highlight on the page'
          },
          color: {
            type: 'string',
            enum: ['yellow', 'blue', 'pink', 'green'],
            description: 'The highlight color. The AI Agent must choose an appropriate color for highlighting.'
          },
          occurrenceIndex: {
            type: 'integer',
            description: 'If there are multiple occurrences of the text, specify the 0-based index of the occurrence to highlight.'
          },
          highlightAll: {
            type: 'boolean',
            description: 'If true, highlights all occurrences of the text on the page.'
          }
        },
        required: ['text']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'remove_highlight',
      description: 'Remove a highlight from the current page.',
      parameters: {
        type: 'object',
        properties: {
          text: {
            type: 'string',
            description: 'The highlighted text to remove'
          }
        },
        required: ['text']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'lookup_word',
      description: 'Look up an English word in the Voca dictionary and show its definition panel to the user.',
      parameters: {
        type: 'object',
        properties: {
          word: {
            type: 'string',
            description: 'The English word to look up'
          }
        },
        required: ['word']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'add_word_to_voca',
      description: 'Add a new English word to the user\'s Voca vocabulary collection for later review.',
      parameters: {
        type: 'object',
        properties: {
          word: {
            type: 'string',
            description: 'The English word to add'
          }
        },
        required: ['word']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'go_to_page',
      description: 'Navigate to a specific page number in the book.',
      parameters: {
        type: 'object',
        properties: {
          page: {
            type: 'integer',
            description: 'The page number to navigate to'
          }
        },
        required: ['page']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'next_page',
      description: 'Go to the next page.',
      parameters: {
        type: 'object',
        properties: {}
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'previous_page',
      description: 'Go to the previous page.',
      parameters: {
        type: 'object',
        properties: {}
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'get_page_content',
      description: 'Get the text content of a page. If page is not specified, returns the current page. If lang is not specified, returns both English and Vietnamese.',
      parameters: {
        type: 'object',
        properties: {
          page: {
            type: 'integer',
            description: 'Page number (optional, defaults to current page)'
          },
          lang: {
            type: 'string',
            enum: ['en', 'vi'],
            description: 'Language (optional, defaults to both)'
          }
        }
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'get_current_context',
      description: 'Get information about what the user is currently reading: page number, view mode, book title.',
      parameters: {
        type: 'object',
        properties: {}
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'switch_view_mode',
      description: 'Switch the reading view mode. \'en\' shows English only, \'vi\' shows Vietnamese only, \'split\' shows bilingual side-by-side. Use when the user asks to change language display.',
      parameters: {
        type: 'object',
        properties: {
          mode: {
            type: 'string',
            enum: ['en', 'vi', 'split'],
            description: 'The view mode: \'en\' (English only), \'vi\' (Vietnamese only), \'split\' (bilingual)'
          }
        },
        required: ['mode']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'list_highlights',
      description: 'List all highlights the user has made on the current page.',
      parameters: {
        type: 'object',
        properties: {}
      }
    }
  }
];

function App() {
  const initialRoute = getInitialRoute();

  // --- Auth & Token states ---
  const [token, setToken] = useState(() => localStorage.getItem('bilingual.reader.token') || '');
  const [isAdmin, setIsAdmin] = useState(() => localStorage.getItem('bilingual.reader.isAdmin') === 'true');
  const [username, setUsername] = useState(() => localStorage.getItem('bilingual.reader.username') || 'User');
  const [profileDropdownOpen, setProfileDropdownOpen] = useState(false);
  const [booksState, setBooksState] = useState([]);
  const [loginUsername, setLoginUsername] = useState('');
  const [loginPassword, setLoginPassword] = useState('');
  const [loginError, setLoginError] = useState('');

  const handleLogout = () => {
    setIsAdmin(false);
    setUsername('User');
    setProfileDropdownOpen(false);
    clearAuthSession(setToken);
    fetch('/api/auth/logout', { method: 'POST', credentials: 'include' });
  };

  // --- Navigation & Book State ---
  const [activeBook, setActiveBook] = useState(initialRoute.book);
  const [page, setPage] = useState(initialRoute.page);
  const [viewMode, setViewMode] = useState(() => {
    if (initialRoute.viewMode) return initialRoute.viewMode;
    return localStorage.getItem('bilingual.reader.viewMode') || 'en';
  }); // 'en' | 'vi' | 'split'
  const [layoutMode, setLayoutMode] = useState(() => {
    return localStorage.getItem('bilingual.reader.layoutMode') || 'en-vi';
  });
  const [fullBookText, setFullBookText] = useState('');

  // Authorized API Fetch wrapper for automatic access token silent refresh
  const apiFetch = async (url, options = {}, allowRefresh = true) => {
    const requestUrl = normalizeApiUrl(url);
    const tok = localStorage.getItem(ACCESS_TOKEN_KEY) || '';
    if (!options.headers) options.headers = {};
    if (tok) options.headers['Authorization'] = `Bearer ${tok}`;
    if (!options.credentials) options.credentials = 'include';

    let res = await fetch(requestUrl, options);
    const canRefresh = allowRefresh && res.status === 401 && (
      tok || localStorage.getItem(REFRESH_TOKEN_KEY)
    );
    if (canRefresh) {
      try {
        const newToken = await refreshAccessToken();
        if (newToken) {
          setToken(newToken);
          options.headers['Authorization'] = `Bearer ${newToken}`;
          return apiFetch(url, options, false);
        }
        clearAuthSession(setToken);
      } catch (err) {
        clearAuthSession(setToken);
      }
    }
    return res;
  };

  // Sync books list on login
  useEffect(() => {
    if (!token) {
      setBooksState([]);
      setIsAdmin(false);
      localStorage.removeItem('bilingual.reader.isAdmin');
      return;
    }
    
    // Fetch User Role info
    apiFetch('api/auth/me')
      .then(res => {
        if (!res.ok) throw new Error('Failed to get user info');
        return res.json();
      })
      .then(data => {
        setIsAdmin(data.is_admin);
        localStorage.setItem('bilingual.reader.isAdmin', data.is_admin);
        setUsername(data.username || 'User');
        localStorage.setItem('bilingual.reader.username', data.username || 'User');
        if (data.is_admin) {
          localStorage.setItem('bilingual.admin.token', token);
        } else {
          localStorage.removeItem('bilingual.admin.token');
        }
      })
      .catch(err => {
        console.warn('Failed fetching user info, logging out...', err);
        clearAuthSession(setToken);
      });

    apiFetch('api/books')
      .then(res => {
        if (!res.ok) throw new Error('Session expired');
        return res.json();
      })
      .then(data => {
        setBooksState(data);
        // If hash match, sync activeBook from API list
        const hash = window.location.hash;
        const readMatch = hash.match(/^#\/read\/([^/]+)(?:\/page\/(\d+))?$/);
        if (readMatch) {
          const slug = readMatch[1];
          const matchedBook = data.find(b => b.slug === slug);
          if (matchedBook) {
            setActiveBook(matchedBook);
            if (readMatch[2]) setPage(parseInt(readMatch[2], 10));
          }
        }
      })
      .catch(err => {
        console.warn('Failed fetching books, logging out...', err);
        clearAuthSession(setToken);
      });
  }, [token]);

  // Sync highlights from server when activeBook changes
  useEffect(() => {
    if (!token || !activeBook) return;
    apiFetch(`api/books/${activeBook.slug}/highlights`)
      .then(res => res.json())
      .then(data => {
        if (data.highlights) {
          saveHighlights(activeBook.slug, data.highlights);
          setBookHighlights(data.highlights);
        }
      })
      .catch(err => console.warn('Failed fetching highlights from server:', err));
  }, [activeBook, token]);

  // Sync progress from server when activeBook changes
  useEffect(() => {
    if (!token || !activeBook) return;
    apiFetch(`api/books/${activeBook.slug}/progress`)
      .then(res => res.json())
      .then(data => {
        if (data.page && data.page !== page) {
          setPage(data.page);
          if (data.viewMode) setViewMode(data.viewMode);
        }
      })
      .catch(err => console.warn('Failed to load progress from server:', err));
  }, [activeBook, token]);

  // Sync page progress back to server when it changes
  useEffect(() => {
    if (!token || !activeBook || page <= 0) return;
    apiFetch(`api/books/${activeBook.slug}/progress`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ page, viewMode })
    }).catch(err => console.warn('Failed saving progress to server:', err));
  }, [activeBook, page, viewMode, token]);

  // --- Dynamic Dashboard Layout & Pagination State ---
  const getColsCount = () => {
    const width = window.innerWidth;
    if (width < 600) return 2;
    if (width < 1000) return 3;
    return 4;
  };
  const [cols, setCols] = useState(getColsCount);
  const [currentPage, setCurrentPage] = useState(1);

  useEffect(() => {
    const handleResize = () => {
      setCols(getColsCount());
    };
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  const sortedBooks = useMemo(() => {
    const listSource = token ? booksState : [];
    if (listSource.length === 0) return [];
    const books = [...listSource];
    // Treat the BOOKS array index as a virtual "addedAt" time.
    // We convert it to a comparable numeric value by spacing indices apart
    // enough so a lastRead timestamp (ms) can overtake it only when it is
    // genuinely more recent than the book's relative add-order.
    // Strategy: assign each book a base score = its index * 1 (relative order).
    // Assign lastRead from localStorage as an absolute ms timestamp.
    // To make them comparable we normalise: the newest book gets a base score
    // equal to Date.now() so that any lastRead older than "now" will be
    // beaten by the most-recently-added book unless the lastRead is even newer.
    const n = books.length;
    const now = Date.now();
    // Space each book's "virtual add time" 1 second apart, with the last book = now
    const addedTimes = books.map((_, i) => now - (n - 1 - i) * 1000);

    return books
      .map((book, i) => {
        const progress = getSavedProgress(book.slug);
        const lastRead = progress?.lastRead ?? 0;
        // The effective sort key is the larger of: when it was added vs when it was last read
        const sortKey = Math.max(addedTimes[i], lastRead);
        return { book, sortKey };
      })
      .sort((a, b) => b.sortKey - a.sortKey)
      .map(({ book }) => book);
  }, [activeBook, booksState, token]);

  const pageSize = cols * 3;
  const totalPages = Math.ceil(sortedBooks.length / pageSize);
  const clampedPage = Math.min(currentPage, Math.max(1, totalPages));

  const paginatedBooks = useMemo(() => {
    const start = (clampedPage - 1) * pageSize;
    return sortedBooks.slice(start, start + pageSize);
  }, [sortedBooks, clampedPage, pageSize]);

  // --- UI Layout State ---
  const [chatOpen, setChatOpen] = useState(() => {
    return localStorage.getItem('bilingual.reader.chatOpen') === 'true';
  });
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [bookHighlights, setBookHighlights] = useState([]);

  // --- API & Settings State ---
  const [settings, setSettings] = useState(() => {
    // Load local CONFIG if available (defined in config.js)
    const localOpenAIKey = typeof CONFIG !== 'undefined' ? CONFIG.OPENAI_API_KEY : '';
    const localGeminiKey = typeof CONFIG !== 'undefined' ? CONFIG.GEMINI_API_KEY : '';

    // Load from LocalStorage
    const saved = localStorage.getItem('bilingual.reader.settings');
    if (saved) {
      try {
        const parsed = JSON.parse(saved);
        // Ensure all required fields exist
        return { ...DEFAULT_SETTINGS, ...parsed };
      } catch (e) {
        console.warn('Failed to parse saved settings', e);
      }
    }

    // Default fallback prioritizing local environment keys
    if (localGeminiKey) {
      return {
        provider: 'gemini',
        baseURL: 'https://generativelanguage.googleapis.com/v1beta/openai',
        apiKey: localGeminiKey,
        model: 'gemini-1.5-flash',
      };
    } else if (localOpenAIKey) {
      return {
        provider: 'openai',
        baseURL: 'https://api.openai.com/v1',
        apiKey: localOpenAIKey,
        model: 'gpt-4o-mini',
      };
    }

    return DEFAULT_SETTINGS;
  });

  // Settings modal fields
  const [formProvider, setFormProvider] = useState(settings.provider);
  const [formBaseURL, setFormBaseURL] = useState(settings.baseURL);
  const [formApiKey, setFormApiKey] = useState(settings.apiKey);
  const [formModel, setFormModel] = useState(settings.model);
  const [formRealtimeApiKey, setFormRealtimeApiKey] = useState(settings.realtimeApiKey || '');
  const [formRealtimeModel, setFormRealtimeModel] = useState(settings.realtimeModel || 'gpt-realtime-mini');
  const [formRealtimeVoice, setFormRealtimeVoice] = useState(settings.realtimeVoice || 'alloy');
  const [formLayoutMode, setFormLayoutMode] = useState(layoutMode);
  const [formVocaBridgeOrigin, setFormVocaBridgeOrigin] = useState(settings.vocaBridgeOrigin || '');
  const [formVocaBridgeToken, setFormVocaBridgeToken] = useState(settings.vocaBridgeToken || '');
  const [formTtsEndpoint, setFormTtsEndpoint] = useState(settings.ttsEndpoint || '');
  const [formTtsModel, setFormTtsModel] = useState(settings.ttsModel || 'edge-tts/en-US-SteffanNeural');

  const openSettings = () => {
    setFormProvider(settings.provider);
    setFormBaseURL(settings.baseURL);
    setFormApiKey(settings.apiKey);
    setFormModel(settings.model);
    setFormRealtimeApiKey(settings.realtimeApiKey || '');
    setFormRealtimeModel(settings.realtimeModel || 'gpt-realtime-mini');
    setFormRealtimeVoice(settings.realtimeVoice || 'alloy');
    setFormLayoutMode(layoutMode);
    setFormVocaBridgeOrigin(settings.vocaBridgeOrigin || '');
    setFormVocaBridgeToken(settings.vocaBridgeToken || '');
    setFormTtsEndpoint(settings.ttsEndpoint || '');
    setFormTtsModel(settings.ttsModel || 'edge-tts/en-US-SteffanNeural');
    setSettingsOpen(true);
  };

  // --- Chat State ---
  const [messages, setMessages] = useState([]);
  const [chatInput, setChatInput] = useState('');
  const [chatPending, setChatPending] = useState(false);
  const [isRecordingMic, setIsRecordingMic] = useState(false);
  const [suggestedPrompts, setSuggestedPrompts] = useState([]);
  const [suggestionsPage, setSuggestionsPage] = useState(-1);

  const messagesEndRef = useRef(null);
  const [popupConfig, setPopupConfig] = useState(null); // { type: 'alert' | 'confirm', title: string, message: string, onConfirm: () => void, onCancel?: () => void }
  const abortControllerRef = useRef(null);
  const recognitionRef = useRef(null);

  // --- WebRTC Realtime Voice State & Refs ---
  const [realtimeVoiceActive, setRealtimeVoiceActive] = useState(false);
  const [realtimeState, setRealtimeState] = useState('idle'); // 'idle' | 'connecting' | 'live' | 'error'
  const [realtimeCaption, setRealtimeCaption] = useState('');
  const [realtimeUserTranscript, setRealtimeUserTranscript] = useState('');
  const [realtimeError, setRealtimeError] = useState('');

  const pcRef = useRef(null);
  const localStreamRef = useRef(null);
  const dataChannelRef = useRef(null);
  const audioElRef = useRef(null);

  // --- Chat Resizing State & Event Handlers ---
  const [chatWidth, setChatWidth] = useState(() => {
    const saved = localStorage.getItem('bilingual.reader.chatWidth');
    return saved ? parseInt(saved, 10) : 400;
  });
  const [isResizing, setIsResizing] = useState(false);
  const isResizingRef = useRef(false);
  const resizingRafRef = useRef(null);

  // Sync layout state to LocalStorage
  useEffect(() => {
    localStorage.setItem('bilingual.reader.viewMode', viewMode);
  }, [viewMode]);

  useEffect(() => {
    localStorage.setItem('bilingual.reader.chatOpen', chatOpen);
  }, [chatOpen]);

  // --- Auto-save Reading Progress ---
  useEffect(() => {
    if (activeBook && page > 0) {
      const progressData = {
        page,
        viewMode,
        lastRead: Date.now()
      };
      localStorage.setItem(`bilingual.reader.progress.${activeBook.slug}`, JSON.stringify(progressData));
    }
  }, [activeBook, page, viewMode]);

  useEffect(() => {
    if (activeBook) {
      setBookHighlights(loadHighlights(activeBook.slug));
    } else {
      setBookHighlights([]);
      removeAllReaderHighlightUI();
    }
  }, [activeBook]);

  useEffect(() => {
    configureVocaClient(() => settings);
  }, [settings]);

  useEffect(() => {
    localStorage.setItem('bilingual.reader.chatWidth', chatWidth);
  }, [chatWidth]);

  const startResizing = (e) => {
    e.preventDefault();
    isResizingRef.current = true;
    setIsResizing(true);
    document.body.classList.add('is-resizing');
    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', stopResizing);
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  };

  const handleMouseMove = (e) => {
    if (!isResizingRef.current) return;
    let newWidth = window.innerWidth - e.clientX;
    if (newWidth < 280) newWidth = 280;
    if (newWidth > 800) newWidth = 800;
    
    // Direct DOM styling updates for maximum performance
    const sidebar = document.querySelector('.chat-sidebar');
    if (sidebar) {
      sidebar.style.width = `${newWidth}px`;
    }

    if (resizingRafRef.current) {
      cancelAnimationFrame(resizingRafRef.current);
    }
    resizingRafRef.current = requestAnimationFrame(() => {
      scaleIframes();
    });
  };

  const stopResizing = () => {
    isResizingRef.current = false;
    setIsResizing(false);
    document.body.classList.remove('is-resizing');
    document.removeEventListener('mousemove', handleMouseMove);
    document.removeEventListener('mouseup', stopResizing);
    document.body.style.cursor = '';
    document.body.style.userSelect = '';

    // Synchronize the final width to Preact state
    const sidebar = document.querySelector('.chat-sidebar');
    if (sidebar) {
      const finalWidth = parseInt(sidebar.style.width, 10);
      if (!isNaN(finalWidth)) {
        setChatWidth(finalWidth);
      }
    }
  };

  useEffect(() => {
    return () => {
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', stopResizing);
      if (resizingRafRef.current) {
        cancelAnimationFrame(resizingRafRef.current);
      }
    };
  }, []);

  // --- Dynamic scaling for iframes to fit standard A4 dimension ---
  const scaleIframes = () => {
    const wrappers = document.querySelectorAll('.iframe-wrapper');
    const panesContainer = document.querySelector('.reader-panes');
    const isVertical = panesContainer && (
      panesContainer.classList.contains('layout-en-over-vi') || 
      panesContainer.classList.contains('layout-vi-over-en')
    );

    wrappers.forEach(wrapper => {
      const iframe = wrapper.querySelector('.reader-iframe');
      if (!iframe) return;

      const containerWidth = wrapper.clientWidth;
      const containerHeight = wrapper.clientHeight;

      const targetWidth = 794;
      const targetHeight = 1123;
      const padding = 20;

      const availableWidth = Math.max(containerWidth - padding, 100);
      const availableHeight = Math.max(containerHeight - padding, 100);

      const scaleX = availableWidth / targetWidth;
      const scaleY = availableHeight / targetHeight;
      
      // If layout is vertical stack, scale to fit the width only and scroll vertically
      const scale = isVertical ? Math.min(scaleX, 1) : Math.min(scaleX, scaleY, 1);

      iframe.style.transform = `scale(${scale})`;
      iframe.style.width = `${targetWidth}px`;
      iframe.style.height = `${targetHeight}px`;
    });
  };

  // Trigger scale adjustment on layout updates
  useEffect(() => {
    const timer = setTimeout(scaleIframes, 50);
    return () => clearTimeout(timer);
  }, [viewMode, chatOpen, chatWidth, page, activeBook, layoutMode]);

  // Handle window resizing
  useEffect(() => {
    window.addEventListener('resize', scaleIframes);
    return () => window.removeEventListener('resize', scaleIframes);
  }, []);

  // Helper to save messages and handle state safely
  const saveChatHistory = (slug, msgs) => {
    if (!slug) return;
    const cleanMsgs = msgs.filter(m => !m.pending);
    if (cleanMsgs.length > 0) {
      const chatHistory = {
        messages: cleanMsgs,
        lastUpdated: Date.now()
      };
      localStorage.setItem(`bilingual.reader.chatHistory.${slug}`, JSON.stringify(chatHistory));
    } else {
      localStorage.removeItem(`bilingual.reader.chatHistory.${slug}`);
    }
  };

  const updateMessagesAndSave = (updater) => {
    setMessages(prev => {
      const next = typeof updater === 'function' ? updater(prev) : updater;
      saveChatHistory(activeBook?.slug, next);
      return next;
    });
  };

  // Register Service Worker on mount
  useEffect(() => {
    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('sw.js')
        .then(reg => {
          console.log('[App] Service Worker registered scope:', reg.scope);
        })
        .catch(err => {
          console.error('[App] Service Worker registration failed:', err);
        });
    }
  }, []);

  // Clear sentence highlights when clicking outside of the iframes
  useEffect(() => {
    const handleParentClick = (e) => {
      if (!e.target.closest('.reader-iframe')) {
        clearAllHighlights();
        removeAllReaderHighlightUI();
      }
      if (!e.target.closest('.profile-menu-container')) {
        setProfileDropdownOpen(false);
      }
    };
    window.addEventListener('click', handleParentClick);
    return () => window.removeEventListener('click', handleParentClick);
  }, []);

  // Synchronize scrolling between English and Vietnamese wrappers (esp. in stacked layouts)
  useEffect(() => {
    const enWrapper = document.querySelector('#en-pane .iframe-wrapper');
    const viWrapper = document.querySelector('#vi-pane .iframe-wrapper');
    if (!enWrapper || !viWrapper) return;

    let isSyncingEnScroll = false;
    let isSyncingViScroll = false;

    const handleEnScroll = () => {
      if (!isSyncingEnScroll) {
        isSyncingViScroll = true;
        viWrapper.scrollTop = enWrapper.scrollTop;
        viWrapper.scrollLeft = enWrapper.scrollLeft;
        setTimeout(() => { isSyncingViScroll = false; }, 20);
      }
    };

    const handleViScroll = () => {
      if (!isSyncingViScroll) {
        isSyncingEnScroll = true;
        enWrapper.scrollTop = viWrapper.scrollTop;
        enWrapper.scrollLeft = viWrapper.scrollLeft;
        setTimeout(() => { isSyncingEnScroll = false; }, 20);
      }
    };

    enWrapper.addEventListener('scroll', handleEnScroll);
    viWrapper.addEventListener('scroll', handleViScroll);

    return () => {
      enWrapper.removeEventListener('scroll', handleEnScroll);
      viWrapper.removeEventListener('scroll', handleViScroll);
    };
  }, [layoutMode, viewMode, page]);

  // Silent background prefetch for book pages when activeBook changes
  useEffect(() => {
    if (!activeBook) return;
    
    const prefetchBook = async () => {
      if (!('caches' in window)) return;
      try {
        const cache = await caches.open('bilingual-reader-books');
        
        // Cache book.html silently
        const bookHtmlUrl = `books/${activeBook.slug}/output/book.html`;
        cache.match(bookHtmlUrl).then(matched => {
          if (!matched) {
            fetch(bookHtmlUrl).then(res => {
              if (res.ok) cache.put(bookHtmlUrl, res);
            }).catch(() => {});
          }
        });

        // Prefetch pages silently
        for (let i = 1; i <= activeBook.pageCount; i++) {
          const pad = String(i).padStart(4, '0');
          const enUrl = `books/${activeBook.slug}/output/en/page_${pad}.html`;
          const viUrl = `books/${activeBook.slug}/output/vi/page_${pad}.html`;

          cache.match(enUrl).then(matched => {
            if (!matched) {
              fetch(enUrl).then(res => {
                if (res.ok) cache.put(enUrl, res);
              }).catch(() => {});
            }
          });

          cache.match(viUrl).then(matched => {
            if (!matched) {
              fetch(viUrl).then(res => {
                if (res.ok) cache.put(viUrl, res);
              }).catch(() => {});
            }
          });
        }
      } catch (e) {
        console.warn("[Cache] Silent background prefetch failed:", e);
      }
    };

    prefetchBook();
  }, [activeBook]);

  // Sync activeBook chat history on change
  useEffect(() => {
    if (activeBook) {
      const saved = localStorage.getItem(`bilingual.reader.chatHistory.${activeBook.slug}`);
      if (saved) {
        try {
          const parsed = JSON.parse(saved);
          setMessages(parsed.messages || []);
          return;
        } catch (e) {
          console.warn('[App] Failed to parse chat history:', e);
        }
      }
    }
    setMessages([]);
  }, [activeBook]);

  // Cleanup expired chat histories (TTL logic)
  useEffect(() => {
    const cleanupExpiredHistories = () => {
      const keys = Object.keys(localStorage);
      const now = Date.now();
      const expireDays = 7; // Hardcoded to 7 days
      
      const expireMs = expireDays * 24 * 60 * 60 * 1000;
      let count = 0;
      
      keys.forEach(key => {
        if (key.startsWith('bilingual.reader.chatHistory.')) {
          try {
            const saved = localStorage.getItem(key);
            if (saved) {
              const parsed = JSON.parse(saved);
              if (parsed.lastUpdated && (now - parsed.lastUpdated > expireMs)) {
                localStorage.removeItem(key);
                count++;
                console.log(`[TTL Cache] Cleaned up expired chat history for key: ${key}`);
              }
            }
          } catch (e) {
            localStorage.removeItem(key);
          }
        }
      });
      if (count > 0) {
        console.log(`[TTL Cache] Successfully cleaned up ${count} expired chat sessions.`);
      }
    };

    cleanupExpiredHistories();
  }, []);

  // Clear active chat
  const handleClearActiveChat = () => {
    setPopupConfig({
      type: 'confirm',
      title: 'Xác nhận xóa',
      message: 'Bạn có muốn xóa lịch sử chat của cuốn sách này?',
      onConfirm: () => {
        updateMessagesAndSave([]);
      }
    });
  };

  // Main window keyboard shortcut listeners
  useEffect(() => {
    const handleKeyDown = (e) => {
      // Skip pagination if the user is typing in a form field
      if (document.activeElement && (document.activeElement.tagName === 'INPUT' || document.activeElement.tagName === 'TEXTAREA')) {
        return;
      }

      if (e.key === 'ArrowLeft' || e.key === 'PageUp') {
        e.preventDefault();
        setPage(p => Math.max(1, p - 1));
      } else if (e.key === 'ArrowRight' || e.key === 'PageDown') {
        e.preventDefault();
        setPage(p => Math.min(activeBook ? activeBook.pageCount : p, p + 1));
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [activeBook]);

  // Iframe content load handler
  const handleIframeLoad = (e) => {
    scaleIframes();
    try {
      const iframeEl = e.target;
      const iframeWin = iframeEl.contentWindow;
      const doc = iframeEl.contentDocument || iframeWin.document;
      if (doc) {
        doc.documentElement.style.overflow = 'hidden';
        doc.body.style.overflow = 'hidden';

        // Hide internal pages redundant navigation controls
        const nav = doc.querySelector('.page-nav');
        if (nav) nav.style.display = 'none';

        const isEnglish = iframeEl.classList.contains('en-pane-iframe');
        const lang = isEnglish ? 'en' : 'vi';
        injectHighlightCSS(doc, isEnglish);

        // Segment sentences in the document
        segmentDocSentences(doc);

        if (activeBook) {
          applyStoredHighlights(doc, activeBook.slug, page, lang);
        }

        // Register highlighting listeners inside the iframe
        registerIframeHighlightListeners(iframeWin, doc, iframeEl, lang);

        // Listen for keys inside the iframe to slide pages
        doc.addEventListener('keydown', (event) => {
          if (event.key === 'ArrowLeft' || event.key === 'PageUp') {
            event.preventDefault();
            setPage(p => Math.max(1, p - 1));
          } else if (event.key === 'ArrowRight' || event.key === 'PageDown') {
            event.preventDefault();
            setPage(p => Math.min(activeBook ? activeBook.pageCount : p, p + 1));
          }
        });
      }
    } catch (err) {
      console.warn("Could not style loaded iframe content: ", err);
    }
  };

  const createHighlight = (selectionInfo, lang, color, note = '') => {
    if (!activeBook || !selectionInfo) return;
    const highlight = {
      id: generateHighlightId(),
      page,
      lang,
      color,
      text: selectionInfo.text,
      startOffset: selectionInfo.startOffset,
      endOffset: selectionInfo.endOffset,
      paragraphIndex: selectionInfo.paragraphIndex,
      note: note || '',
      createdAt: Date.now(),
    };
    const next = [...bookHighlights, highlight];
    saveHighlights(activeBook.slug, next);
    setBookHighlights(next);
    reapplyHighlightsInIframes(activeBook.slug, page, lang);
    document.querySelectorAll('.reader-iframe').forEach(iframe => {
      iframe.contentWindow?.getSelection()?.removeAllRanges();
    });
    removeAllReaderHighlightUI();

    // Sync to Server
    apiFetch(`api/books/${activeBook.slug}/highlights`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(highlight)
    }).catch(err => console.warn(err));

    return highlight;
  };

  const updateHighlight = (id, updates) => {
    if (!activeBook) return;
    const next = bookHighlights.map(h => h.id === id ? { ...h, ...updates } : h);
    saveHighlights(activeBook.slug, next);
    setBookHighlights(next);
    const target = next.find(h => h.id === id);
    if (target) {
      reapplyHighlightsInIframes(activeBook.slug, target.page, target.lang);

      // Sync to Server
      apiFetch(`api/books/${activeBook.slug}/highlights`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(target)
      }).catch(err => console.warn(err));
    }
    removeAllReaderHighlightUI();
  };

  const deleteHighlight = (id) => {
    if (!activeBook) return;
    const target = bookHighlights.find(h => h.id === id);
    const next = bookHighlights.filter(h => h.id !== id);
    saveHighlights(activeBook.slug, next);
    setBookHighlights(next);
    if (target) {
      reapplyHighlightsInIframes(activeBook.slug, target.page, target.lang);

      // Sync to Server
      apiFetch(`api/books/${activeBook.slug}/highlights/${id}`, {
        method: 'DELETE'
      }).catch(err => console.warn(err));
    }
    removeAllReaderHighlightUI();
  };

  useEffect(() => {
    if (!activeBook) {
      highlightAppContext = null;
      return;
    }
    highlightAppContext = {
      slug: activeBook.slug,
      page,
      setBookHighlights,
      createHighlight,
      updateHighlight,
      deleteHighlight,
    };
    return () => {
      highlightAppContext = null;
    };
  }, [activeBook, page, bookHighlights]);

  // --- Router hash controller ---
  useEffect(() => {
    function handleHashChange() {
      const hash = window.location.hash;
      if (!hash || hash === '#/') {
        setActiveBook(null);
        setPage(1);
        return;
      }

      // Pattern: #/read/:slug or #/read/:slug/page/:num
      const readMatch = hash.match(/^#\/read\/([^/]+)(?:\/page\/(\d+))?$/);
      if (readMatch) {
        const slug = readMatch[1];
        const savedProgress = getSavedProgress(slug);
        const pageNum = readMatch[2]
          ? parseInt(readMatch[2], 10)
          : (savedProgress?.page || 1);

        // Find book in appropriate list source
        const listSource = token ? booksState : [];
        const book = listSource.find(b => b.slug === slug);
        if (book) {
          setActiveBook(book);
          setPage(pageNum);
          if (savedProgress?.viewMode && !readMatch[2]) {
            setViewMode(savedProgress.viewMode);
          }
        } else if (token && booksState.length === 0) {
          // If logged in but booksState is not loaded yet, set a skeleton activeBook
          // to prevent redirecting before books are fetched.
          setActiveBook({ slug });
          setPage(pageNum);
        } else {
          // Fallback if book slug not found and loading is complete
          window.location.hash = '#/';
        }
      }
    }

    window.addEventListener('hashchange', handleHashChange);
    handleHashChange(); // Run once on load

    return () => window.removeEventListener('hashchange', handleHashChange);
  }, [booksState, token]);

  // Sync hash with active book / page changes
  useEffect(() => {
    if (activeBook) {
      window.location.hash = `#/read/${activeBook.slug}/page/${page}`;
    } else {
      window.location.hash = '#/';
    }
  }, [activeBook, page]);

  // Generate dynamic suggestion prompts on page load/change
  useEffect(() => {
    if (!activeBook || !settings.apiKey) return;
    if (suggestionsPage === page) return;

    const generateSuggestions = async () => {
      const activePageText = getIframePageText();
      if (!activePageText) return;

      const systemPrompt = `You generate 3 contextual question suggestions for a reader. The reader is reading page ${page} of "${activeBook.title}".

PAGE CONTENT:
${activePageText.slice(0, 2000)}

Return ONLY a JSON array of exactly 3 objects, each with:
- "icon": a single emoji that fits the question theme
- "title": short title in Vietnamese (max 20 chars)
- "prompt": the full question in Vietnamese (1-2 sentences)

The questions should be specific to THIS page content, not generic. Focus on:
- Key concepts, terminology, or ideas mentioned on this page
- Interesting connections or deeper analysis
- Practical applications or real-world relevance

Example format: [{"icon":"🧠","title":"Khái niệm X","prompt":"Giải thích khái niệm X được đề cập trong trang này..."}]
Return ONLY the JSON array, no other text.`;

      try {
        const response = await apiFetch('/api/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            baseURL: settings.baseURL,
            apiKey: settings.apiKey,
            model: settings.model,
            messages: [
              { role: 'system', content: systemPrompt },
              { role: 'user', content: 'Generate 3 suggestion prompts for this page.' }
            ],
            stream: false
          })
        });

        if (response.ok) {
          const data = await response.json();
          const text = data.choices?.[0]?.message?.content || '';
          const cleaned = text.trim()
            .replace(/^```json/i, '')
            .replace(/```$/, '')
            .trim();
          
          try {
            const arr = JSON.parse(cleaned);
            if (Array.isArray(arr)) {
              setSuggestedPrompts(arr.slice(0, 3));
              setSuggestionsPage(page);
            }
          } catch (e) {
            console.warn('[Companion] Failed to parse suggested prompts JSON:', e);
          }
        }
      } catch (err) {
        console.warn('[Companion] Failed to fetch dynamic suggestions:', err);
      }
    };

    const timer = setTimeout(generateSuggestions, 600);
    return () => clearTimeout(timer);
  }, [activeBook, page, settings.apiKey, suggestionsPage]);

  // Load full book text asynchronously for AI context
  useEffect(() => {
    if (!activeBook) {
      setFullBookText('');
      return;
    }

    setFullBookText('Loading book context...');
    fetch(`books/${activeBook.slug}/output/book.html`)
      .then(res => {
        if (!res.ok) throw new Error('Book HTML not found');
        return res.text();
      })
      .then(htmlContent => {
        const parser = new DOMParser();
        const doc = parser.parseFromString(htmlContent, 'text/html');
        // Extract clean text content from articles/sheets
        const text = doc.body.innerText || '';
        // Truncate if unreasonably massive, but standard LLM contexts support it.
        setFullBookText(text);
      })
      .catch(err => {
        console.error('Failed to pre-load full book context:', err);
        setFullBookText('Unable to load full book context.');
      });
  }, [activeBook]);

  // Scroll to bottom of chat
  useEffect(() => {
    if (messagesEndRef.current) {
      messagesEndRef.current.scrollIntoView({ behavior: 'auto' });
    }
  }, [messages, chatPending]);

  // Handle setting provider autofills
  const onProviderChange = (e) => {
    const prov = e.target.value;
    setFormProvider(prov);
    if (prov === 'openai') {
      setFormBaseURL('https://api.openai.com/v1');
      setFormModel('gpt-4o-mini');
    } else if (prov === 'gemini') {
      setFormBaseURL('https://generativelanguage.googleapis.com/v1beta/openai');
      setFormModel('gemini-1.5-flash');
    }
  };

  const saveSettings = (e) => {
    e.preventDefault();
    const updated = {
      provider: formProvider,
      baseURL: formBaseURL,
      apiKey: formApiKey,
      model: formModel,
      realtimeApiKey: formRealtimeApiKey.trim(),
      realtimeModel: formRealtimeModel.trim(),
      realtimeVoice: formRealtimeVoice.trim(),
      vocaBridgeOrigin: formVocaBridgeOrigin.trim(),
      vocaBridgeToken: formVocaBridgeToken.trim(),
      ttsEndpoint: formTtsEndpoint.trim(),
      ttsModel: formTtsModel.trim(),
      useApiTts: true,
    };
    setSettings(updated);
    localStorage.setItem('bilingual.reader.settings', JSON.stringify(updated));
    
    setLayoutMode(formLayoutMode);
    localStorage.setItem('bilingual.reader.layoutMode', formLayoutMode);
    
    setSettingsOpen(false);
  };

  // Extract text from the active iframe(s) DOM
  const getIframePageText = () => {
    let pageText = '';
    
    // Left pane (English)
    const enIframe = document.querySelector('.en-pane-iframe');
    if (enIframe && enIframe.contentDocument) {
      const txt = enIframe.contentDocument.body.innerText.trim();
      if (txt) {
        pageText += `=== ENGLISH PAGE ${page} ===\n${txt}\n\n`;
      }
    }

    // Right pane (Vietnamese)
    const viIframe = document.querySelector('.vi-pane-iframe');
    if (viIframe && viIframe.contentDocument) {
      const txt = viIframe.contentDocument.body.innerText.trim();
      if (txt) {
        pageText += `=== VIETNAMESE PAGE ${page} ===\n${txt}\n\n`;
      }
    }

    return pageText.trim();
  };

  const findOccurrencesInDoc = (doc, searchText) => {
    if (!doc) return [];
    const paragraphs = getParagraphs(doc);
    const occurrences = [];

    // Pass 1: exact match
    for (let i = 0; i < paragraphs.length; i++) {
      const pText = paragraphs[i].textContent;
      let idx = pText.indexOf(searchText);
      while (idx >= 0) {
        occurrences.push({
          paragraphIndex: i,
          startOffset: idx,
          endOffset: idx + searchText.length,
          context: pText.trim()
        });
        idx = pText.indexOf(searchText, idx + 1);
      }
    }

    // Pass 2: case-insensitive fallback
    if (occurrences.length === 0) {
      const lowerSearch = searchText.toLowerCase();
      for (let i = 0; i < paragraphs.length; i++) {
        const pText = paragraphs[i].textContent;
        const lowerPText = pText.toLowerCase();
        let idx = lowerPText.indexOf(lowerSearch);
        while (idx >= 0) {
          occurrences.push({
            paragraphIndex: i,
            startOffset: idx,
            endOffset: idx + searchText.length,
            context: pText.trim()
          });
          idx = lowerPText.indexOf(lowerSearch, idx + 1);
        }
      }
    }
    return occurrences;
  };

  const executeWebTool = async (name, args) => {
    switch (name) {
      case 'highlight_text': {
        const text = args.text;
        const colorName = args.color || 'yellow';
        const colorHex = colorMap[colorName] || '#fde68a';
        const occurrenceIndex = args.occurrenceIndex !== undefined ? args.occurrenceIndex : null;
        const highlightAll = args.highlightAll || false;

        const langs = viewMode === 'split' ? ['en', 'vi'] : [viewMode];
        let allOccurrences = [];

        for (const lang of langs) {
          const selector = lang === 'en' ? '.en-pane-iframe' : '.vi-pane-iframe';
          const iframe = document.querySelector(selector);
          if (!iframe?.contentDocument) continue;
          const doc = iframe.contentDocument;

          const occurrences = findOccurrencesInDoc(doc, text);
          if (occurrences.length > 0) {
            occurrences.forEach(o => { o.lang = lang; });
            allOccurrences.push(...occurrences);
          }
        }

        if (allOccurrences.length === 0) {
          return { success: false, error: 'text_not_found', message: `Text '${text}' not found on this page.` };
        }

        if (allOccurrences.length > 1 && occurrenceIndex === null && !highlightAll) {
          return {
            success: false,
            error: 'multiple_occurrences',
            message: `Found ${allOccurrences.length} occurrences of '${text}' on the current page.`,
            occurrences: allOccurrences
          };
        }

        // Determine targets
        let targets = [];
        if (highlightAll) {
          targets = allOccurrences;
        } else if (occurrenceIndex !== null) {
          if (occurrenceIndex < 0 || occurrenceIndex >= allOccurrences.length) {
            return { success: false, error: 'invalid_occurrence_index' };
          }
          targets = [allOccurrences[occurrenceIndex]];
        } else {
          targets = [allOccurrences[0]];
        }

        const createdHighlights = [];
        for (const occ of targets) {
          const selector = occ.lang === 'en' ? '.en-pane-iframe' : '.vi-pane-iframe';
          const iframe = document.querySelector(selector);
          if (!iframe?.contentDocument) continue;
          const doc = iframe.contentDocument;
          const paragraphs = getParagraphs(doc);
          const paragraph = paragraphs[occ.paragraphIndex];
          
          const highlightId = generateHighlightId();
          const highlightData = {
            id: highlightId,
            color: colorHex,
            note: ''
          };

          const ok = wrapTextRange(doc, paragraph, occ.startOffset, occ.endOffset, highlightData);
          if (ok) {
            const highlight = {
              id: highlightId,
              page,
              lang: occ.lang,
              color: colorHex,
              text: text,
              startOffset: occ.startOffset,
              endOffset: occ.endOffset,
              paragraphIndex: occ.paragraphIndex,
              note: '',
              createdAt: Date.now()
            };
            
            // Save local state
            setBookHighlights(prev => [...prev, highlight]);
            
            // Save local storage
            const currentList = loadHighlights(activeBook.slug);
            saveHighlights(activeBook.slug, [...currentList, highlight]);

            // Sync to Server
            apiFetch(`api/books/${activeBook.slug}/highlights`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(highlight)
            }).catch(err => console.warn(err));

            createdHighlights.push(highlight);
          }
        }

        if (createdHighlights.length > 0) {
          return { success: true, message: `Successfully highlighted ${createdHighlights.length} occurrences.` };
        }

        return { success: false, error: 'wrap_failed' };
      }
      
      case 'remove_highlight': {
        const text = args.text;
        const existing = bookHighlights.find(h => h.text.toLowerCase() === text.toLowerCase() && h.page === page);
        if (existing) {
          deleteHighlight(existing.id);
          return { success: true };
        }
        return { success: false, error: 'highlight_not_found' };
      }

      case 'lookup_word': {
        const word = args.word;
        try {
          const result = await lookupWord(word);
          if (result.found) {
            const enIframe = document.querySelector('.en-pane-iframe');
            if (enIframe?.contentDocument) {
              const doc = enIframe.contentDocument;
              const rect = { left: 150, top: 150, width: 0, height: 0 };
              showVocaLookupResults(doc, rect, word, result);
            }
            return { success: true, definition: result.cards || result.card };
          } else {
            return { success: false, error: 'word_not_found_in_dictionary' };
          }
        } catch (err) {
          return { success: false, error: err.message };
        }
      }

      case 'add_word_to_voca': {
        const word = args.word;
        try {
          await addWordToVoca(word);
          return { success: true };
        } catch (err) {
          return { success: false, error: err.message };
        }
      }

      case 'go_to_page': {
        const targetPage = args.page;
        if (targetPage >= 1 && targetPage <= activeBook.pageCount) {
          setPage(targetPage);
          return { success: true };
        }
        return { success: false, error: 'page_out_of_bounds' };
      }

      case 'next_page': {
        if (page < activeBook.pageCount) {
          setPage(p => p + 1);
          return { success: true };
        }
        return { success: false, error: 'already_at_last_page' };
      }

      case 'previous_page': {
        if (page > 1) {
          setPage(p => p - 1);
          return { success: true };
        }
        return { success: false, error: 'already_at_first_page' };
      }

      case 'get_page_content': {
        const targetPage = args.page || page;
        const lang = args.lang;
        let content = '';
        
        if (!lang || lang === 'en') {
          const enIframe = document.querySelector('.en-pane-iframe');
          if (enIframe?.contentDocument) {
            content += `[English Page ${targetPage}]:\n${enIframe.contentDocument.body.innerText}\n`;
          }
        }
        if (!lang || lang === 'vi') {
          const viIframe = document.querySelector('.vi-pane-iframe');
          if (viIframe?.contentDocument) {
            content += `[Vietnamese Page ${targetPage}]:\n${viIframe.contentDocument.body.innerText}\n`;
          }
        }
        return { success: true, content: content.trim() };
      }

      case 'get_current_context': {
        return {
          success: true,
          page,
          totalPages: activeBook.pageCount,
          viewMode,
          bookTitle: activeBook.title,
          bookAuthor: activeBook.author || 'Unknown'
        };
      }

      case 'switch_view_mode': {
        const mode = args.mode;
        if (['en', 'vi', 'split'].includes(mode)) {
          setViewMode(mode);
          return { success: true };
        }
        return { success: false, error: 'invalid_mode' };
      }

      case 'list_highlights': {
        const pageHighlights = bookHighlights.filter(h => h.page === page);
        return {
          success: true,
          highlights: pageHighlights.map(h => ({
            text: h.text,
            color: h.color,
            lang: h.lang,
            note: h.note
          }))
        };
      }

      default:
        return { success: false, error: `Unknown tool: ${name}` };
    }
  };

  const handleExecutedTools = async (toolCalls, history, assistantReply) => {
    const assistantMsg = {
      role: 'assistant',
      content: assistantReply || '',
      tool_calls: toolCalls.map(tc => ({
        id: tc.id,
        type: 'function',
        function: {
          name: tc.name,
          arguments: tc.arguments
        }
      }))
    };

    const nextHistory = [...history, assistantMsg];
    updateMessagesAndSave(nextHistory);

    for (const tc of toolCalls) {
      let output = { success: false, error: 'Unknown error' };
      try {
        const args = JSON.parse(tc.arguments || '{}');
        output = await executeWebTool(tc.name, args);
      } catch (err) {
        output = { success: false, error: err.message };
      }

      const toolMsg = {
        role: 'tool',
        tool_call_id: tc.id,
        name: tc.name,
        content: JSON.stringify(output)
      };
      nextHistory.push(toolMsg);
    }

    updateMessagesAndSave(nextHistory);
    await sendChatCompletionsWithHistory(nextHistory);
  };

  const sendChatCompletionsWithHistory = async (history) => {
    setChatPending(true);
    updateMessagesAndSave([...history, { role: 'assistant', content: '', pending: true }]);

    const activePageText = getIframePageText();
    const cleanFullTextContext = fullBookText && fullBookText !== 'Loading book context...' && fullBookText !== 'Unable to load full book context.'
      ? fullBookText.slice(0, 150000)
      : 'No global book context loaded.';

    const systemPrompt = `You are a helpful, expert AI Reading Companion Agent (named "Companion Reader Agent"). You are guiding the user who is reading the book "${activeBook.title}" by ${activeBook.author}.
The user is currently reading page ${page}.

CURRENT PAGE CONTEXT:
${activePageText}

FULL BOOK BACKGROUND (clean text sample):
${cleanFullTextContext}

Instructions:
1. Answer the user's questions accurately based on the current page and full book context provided.
2. If the user asks about something on this page, prioritize the CURRENT PAGE CONTEXT.
3. If they ask about overall book concepts, utilize the FULL BOOK BACKGROUND.
4. Keep your responses structured, clear, and scan-friendly (use short markdown paragraphs, lists, or bold highlights).
5. Please answer in Vietnamese (the user's language) unless they ask you to write or explain in English. Keep code snippets in their original programming language.
6. Use the available tools when the user asks to highlight, look up words, navigate pages, list highlights, or change view mode.
7. Under TOOLS section:
   * Color names for highlight_text: "yellow", "blue", "pink", "green". Choose a color based on variety or context. Do not ask the user for a color unless they specify it.
   * If highlight_text returns a "multiple_occurrences" error, read the list of occurrences and ask the user to confirm:
     1) Which specific occurrence they want to highlight (describe them by paragraph context or reading order), OR
     2) If they want to highlight all occurrences on the page.
   * Once the user confirms, call highlight_text again passing either 'occurrenceIndex' or 'highlightAll'.
`;

    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
    }
    abortControllerRef.current = new AbortController();
    const signal = abortControllerRef.current.signal;

    try {
      const response = await apiFetch('/api/chat', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        signal,
        body: JSON.stringify({
          baseURL: settings.baseURL,
          apiKey: settings.apiKey,
          model: settings.model,
          messages: [
            { role: 'system', content: systemPrompt },
            ...history.map(m => {
              const cleanM = { role: m.role, content: m.content || '' };
              if (m.tool_calls) cleanM.tool_calls = m.tool_calls;
              if (m.tool_call_id) cleanM.tool_call_id = m.tool_call_id;
              if (m.name) cleanM.name = m.name;
              return cleanM;
            })
          ],
          tools: webToolDefinitions,
          stream: true
        })
      });

      if (!response.ok) {
        if (response.status === 401) {
          clearAuthSession(setToken);
          throw new Error('Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.');
        }
        let detail = '';
        try {
          detail = await response.text();
        } catch (e) {}
        const parsedDetail = (() => {
          try {
            const json = JSON.parse(detail);
            return json.detail || json.error?.message || detail;
          } catch (e) {
            return detail;
          }
        })();
        throw new Error(`Lỗi AI (${response.status}): ${parsedDetail || response.statusText}`);
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder('utf-8');
      let assistantReply = '';
      let currentToolCalls = [];
      let doneStreaming = false;
      let buffer = '';

      const processLine = (line) => {
        const cleanLine = line.trim();
        if (cleanLine === 'data: [DONE]') {
          doneStreaming = true;
          return;
        }
        if (!cleanLine) return;

        if (cleanLine.startsWith('data: ')) {
          try {
            const data = JSON.parse(cleanLine.slice(6));
            const delta = data.choices?.[0]?.delta;
            if (!delta) return;

            if (delta.content) {
              assistantReply += delta.content;
              updateMessagesAndSave([...history, {
                role: 'assistant',
                content: assistantReply,
                pending: false
              }]);
            }

            if (delta.tool_calls) {
              for (const tc of delta.tool_calls) {
                const idx = tc.index;
                if (!currentToolCalls[idx]) {
                  currentToolCalls[idx] = { id: '', name: '', arguments: '' };
                }
                if (tc.id) currentToolCalls[idx].id = tc.id;
                if (tc.function) {
                  if (tc.function.name) currentToolCalls[idx].name += tc.function.name;
                  if (tc.function.arguments) currentToolCalls[idx].arguments += tc.function.arguments;
                }
              }
            }
          } catch (e) {
            // Ignore parse errors
          }
        }
      };

      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          if (buffer) {
            processLine(buffer);
          }
          break;
        }

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop();

        for (const line of lines) {
          processLine(line);
          if (doneStreaming) break;
        }
        if (doneStreaming) {
          try { await reader.cancel(); } catch (e) {}
          break;
        }
      }

      const finalAssistantMsg = { role: 'assistant', content: assistantReply };

      if (currentToolCalls.length > 0) {
        updateMessagesAndSave([...history, finalAssistantMsg]);
        await handleExecutedTools(currentToolCalls, history, assistantReply);
      } else {
        updateMessagesAndSave([...history, finalAssistantMsg]);
        setChatPending(false);
      }
    } catch (err) {
      if (err.name === 'AbortError') {
        console.log('AI chat generation aborted by user.');
        updateMessagesAndSave([...history, {
          role: 'assistant',
          content: 'Yêu cầu đã bị hủy.',
          pending: false
        }]);
      } else {
        console.error('AI chat assistant error:', err);
        updateMessagesAndSave([...history, {
          role: 'assistant',
          content: `Xin lỗi, đã xảy ra lỗi khi kết nối với AI Model: ${err.message}. Vui lòng kiểm tra lại cấu hình API Key hoặc kết nối mạng trong phần Settings!`,
          pending: false
        }]);
      }
      setChatPending(false);
    }
  };

  // AI Chat submission handler
  const sendChatMessage = async (userInputText = null) => {
    const textToSend = userInputText || chatInput;
    if (!textToSend.trim() || chatPending) return;

    if (!settings.apiKey) {
      setPopupConfig({
        type: 'alert',
        title: 'Thiếu API Key',
        message: 'Vui lòng vào Settings cài đặt API Key để chat với Companion Reader Agent!',
        onConfirm: () => {
          openSettings();
        }
      });
      return;
    }

    const newUserMsg = { role: 'user', content: textToSend };
    const nextHistory = [...messages, newUserMsg];
    updateMessagesAndSave(nextHistory);
    setChatInput('');

    await sendChatCompletionsWithHistory(nextHistory);
  };

  const toggleSpeechRecognition = () => {
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) {
      showVocaError('Trình duyệt của bạn không hỗ trợ nhận diện giọng nói (Speech Recognition).');
      return;
    }

    if (isRecordingMic) {
      recognitionRef.current?.stop();
      setIsRecordingMic(false);
    } else {
      const rec = new SpeechRecognition();
      rec.lang = 'vi-VN';
      rec.continuous = false;
      rec.interimResults = false;
      
      rec.onstart = () => {
        setIsRecordingMic(true);
      };
      
      rec.onresult = (e) => {
        const transcript = e.results[0][0].transcript;
        if (transcript) {
          setChatInput(prev => (prev ? prev + ' ' : '') + transcript);
        }
      };
      
      rec.onerror = (e) => {
        console.warn('Speech recognition error:', e);
        setIsRecordingMic(false);
      };
      
      rec.onend = () => {
        setIsRecordingMic(false);
      };

      recognitionRef.current = rec;
      rec.start();
    }
  };

  const startRealtimeVoice = async () => {
    const activeApiKey = settings.realtimeApiKey || settings.apiKey;
    if (!activeApiKey) {
      showVocaError('Vui lòng cài đặt API Key trong Settings trước.');
      return;
    }
    setRealtimeState('connecting');
    setRealtimeVoiceActive(true);
    setRealtimeError('');
    setRealtimeCaption('');
    setRealtimeUserTranscript('');

    try {
      // 1. Get microphone access
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      localStreamRef.current = stream;

      // 2. Fetch ephemeral key from OpenAI Realtime sessions endpoint
      const realtimeModel = settings.realtimeModel || 'gpt-realtime-mini';
      const realtimeVoice = settings.realtimeVoice || 'alloy';
      
      const activePageText = getIframePageText();
      const cleanFullTextContext = fullBookText && fullBookText !== 'Loading book context...' && fullBookText !== 'Unable to load full book context.'
        ? fullBookText.slice(0, 10000)
        : 'No global book context loaded.';

      const systemPrompt = `Your name is Companion Reader Agent. You are an AI reading companion for the bilingual book "${activeBook.title}" by ${activeBook.author || 'Unknown'}.
The user is currently reading page ${page}.

CURRENT PAGE CONTEXT:
${activePageText}

FULL BOOK BACKGROUND (clean text sample):
${cleanFullTextContext}

Instructions:
1. Speak in Vietnamese by default. Only switch to English if the user asks you to.
2. Keep your spoken responses concise and conversational (1-2 sentences max) as this is a real-time voice chat.
3. Use the available tools when the user asks to highlight, look up words, navigate pages, list highlights, or change view mode.
4. Choose highlight colors (yellow, blue, pink, green) yourself. Do not ask the user for a color.
5. If highlight_text returns a "multiple_occurrences" error, read the contexts and ask the user to confirm which one they want to highlight, or if they want to highlight all.
`;

      const sessionResponse = await apiFetch('/api/chat/realtime/session', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          apiKey: activeApiKey,
          session: {
            type: 'realtime',
            model: realtimeModel,
            instructions: systemPrompt
          }
        })
      });

      if (!sessionResponse.ok) {
        let errMsg = `Failed to create session: ${sessionResponse.statusText}`;
        try {
          const errData = await sessionResponse.json();
          if (errData && errData.detail) {
            errMsg = errData.detail;
          }
        } catch (_) {}
        throw new Error(errMsg);
      }

      const sessionData = await sessionResponse.json();
      const ephemeralKey = sessionData.client_secret?.value || sessionData.value;
      if (!ephemeralKey) {
        throw new Error('No ephemeral key returned from OpenAI');
      }

      // 3. Create RTCPeerConnection
      const pc = new RTCPeerConnection();
      pcRef.current = pc;

      // Add local audio tracks to peer connection
      stream.getTracks().forEach(track => pc.addTrack(track, stream));

      // Setup remote audio stream playback
      const remoteStream = new MediaStream();
      pc.ontrack = (e) => {
        remoteStream.addTrack(e.track);
      };

      const audioEl = document.createElement('audio');
      audioEl.autoplay = true;
      audioEl.srcObject = remoteStream;
      document.body.appendChild(audioEl);
      audioElRef.current = audioEl;

      // 4. Create data channel for OpenAI Realtime events
      const dc = pc.createDataChannel('oai-events');
      dataChannelRef.current = dc;

      dc.addEventListener('open', () => {
        setRealtimeState('live');
        
        // Configure voice, modalities, tools, and transcription on data channel connection
        const updateEvent = {
          type: 'session.update',
          session: {
            modalities: ['text', 'audio'],
            voice: realtimeVoice,
            input_audio_transcription: {
              model: 'whisper-1'
            },
            tools: webToolDefinitions.map(t => ({
              type: 'function',
              name: t.function.name,
              description: t.function.description,
              parameters: t.function.parameters
            }))
          }
        };
        dc.send(JSON.stringify(updateEvent));
      });

      dc.addEventListener('message', async (e) => {
        try {
          const oaiEvent = JSON.parse(e.data);
          
          // AI speaking caption updates
          if (oaiEvent.type === 'response.audio_transcript.delta') {
            setRealtimeCaption(prev => prev + oaiEvent.delta);
          }
          if (oaiEvent.type === 'response.audio_transcript.done') {
            setRealtimeCaption(oaiEvent.transcript);
            const newMsg = { role: 'assistant', content: oaiEvent.transcript };
            updateMessagesAndSave(prev => [...prev, newMsg]);
          }

          // User speech transcript updates
          if (oaiEvent.type === 'conversation.item.input_audio_transcription.completed') {
            const transcript = oaiEvent.transcript || '';
            setRealtimeUserTranscript(transcript);
            const newMsg = { role: 'user', content: transcript };
            updateMessagesAndSave(prev => [...prev, newMsg]);
          }

          // User speech started (AI interrupted)
          if (oaiEvent.type === 'input_audio_buffer.speech_started') {
            setRealtimeCaption('...');
            if (audioElRef.current) {
              audioElRef.current.pause();
              audioElRef.current.currentTime = 0;
              audioElRef.current.play().catch(() => {});
            }
          }

          // Handle tool/function calls
          if (oaiEvent.type === 'response.done') {
            const output = oaiEvent.response?.output;
            if (output) {
              for (const item of output) {
                if (item.type === 'function_call') {
                  const result = await executeWebTool(item.name, JSON.parse(item.arguments));
                  
                  // Send tool result back to OpenAI
                  const responseEvent = {
                    type: 'conversation.item.create',
                    item: {
                      type: 'function_call_output',
                      call_id: item.id,
                      output: JSON.stringify(result)
                    }
                  };
                  dc.send(JSON.stringify(responseEvent));
                  
                  // Ask AI to generate verbal response
                  dc.send(JSON.stringify({ type: 'response.create' }));
                  setRealtimeCaption('🔄 Đang xử lý...');
                }
              }
            }
          }
        } catch (err) {
          console.warn('Error parsing OpenAI event:', err);
        }
      });

      // 5. SDP Offer Handshake
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      const sdpResponse = await fetch('https://api.openai.com/v1/realtime/calls', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${ephemeralKey}`,
          'Content-Type': 'application/sdp'
        },
        body: offer.sdp
      });

      if (!sdpResponse.ok) {
        let errorDetails = '';
        try {
          errorDetails = await sdpResponse.text();
        } catch (_) {}
        throw new Error(`SDP Exchange failed: ${sdpResponse.statusText || sdpResponse.status}. Details: ${errorDetails}`);
      }

      const answerSdp = await sdpResponse.text();
      await pc.setRemoteDescription({
        type: 'answer',
        sdp: answerSdp
      });

    } catch (err) {
      console.error('[Realtime Voice Error]', err);
      setRealtimeError(err.message || 'Không thể kết nối Voice Mode.');
      setRealtimeState('error');
      stopRealtimeVoice();
    }
  };

  const stopRealtimeVoice = () => {
    pcRef.current?.close();
    pcRef.current = null;

    localStreamRef.current?.getTracks().forEach(track => track.stop());
    localStreamRef.current = null;

    dataChannelRef.current = null;

    audioElRef.current?.remove();
    audioElRef.current = null;

    setRealtimeVoiceActive(false);
    setRealtimeState('idle');
  };

  useEffect(() => {
    if (!chatOpen || !activeBook) {
      if (pcRef.current) {
        stopRealtimeVoice();
      }
    }
  }, [chatOpen, activeBook]);

  const handleCancelChat = () => {
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }
    setChatPending(false);
    updateMessagesAndSave(prev => {
      const copy = [...prev];
      let targetIdx = -1;
      for (let i = copy.length - 1; i >= 0; i--) {
        if (copy[i].role === 'assistant') {
          targetIdx = i;
          break;
        }
      }
      if (targetIdx !== -1 && copy[targetIdx].pending) {
        copy[targetIdx] = {
          ...copy[targetIdx],
          pending: false
        };
      }
      return copy;
    });
  };

  const handleQuickPrompt = (promptText) => {
    sendChatMessage(promptText);
  };

  // Helper to parse inline markdown elements: bold (**), italic (*), and inline code (`)
  const parseInlineFormatting = (text) => {
    const regex = /(\*\*.*?\*\*|\*.*?\*|`.*?`)/g;
    const parts = text.split(regex);
    return parts.map((part, idx) => {
      if (part.startsWith('**') && part.endsWith('**')) {
        return html`<strong key=${idx}>${part.slice(2, -2)}</strong>`;
      }
      if (part.startsWith('*') && part.endsWith('*')) {
        return html`<em key=${idx}>${part.slice(1, -1)}</em>`;
      }
      if (part.startsWith('`') && part.endsWith('`')) {
        return html`<code class="inline-code" key=${idx}>${part.slice(1, -1)}</code>`;
      }
      return part;
    });
  };

  // Formatting helper to render markdown elements in blocks
  const renderMessageContent = (content) => {
    const lines = content.split('\n');
    let inCodeBlock = false;
    let codeContent = [];
    const elements = [];
    let keyIdx = 0;
    
    let listItems = [];
    let listType = null; // 'ul' | 'ol'

    const flushList = () => {
      if (listItems.length > 0) {
        const itemElements = listItems.map((item, idx) => html`<li key=${idx}>${parseInlineFormatting(item)}</li>`);
        if (listType === 'ul') {
          elements.push(html`<ul key=${keyIdx++}>${itemElements}</ul>`);
        } else if (listType === 'ol') {
          elements.push(html`<ol key=${keyIdx++}>${itemElements}</ol>`);
        }
        listItems = [];
        listType = null;
      }
    };

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];

      if (line.trim().startsWith('```')) {
        flushList();
        if (inCodeBlock) {
          inCodeBlock = false;
          elements.push(html`<pre key=${keyIdx++}><code>${codeContent.join('\n')}</code></pre>`);
          codeContent = [];
        } else {
          inCodeBlock = true;
        }
        continue;
      }

      if (inCodeBlock) {
        codeContent.push(line);
        continue;
      }

      const trimmed = line.trim();
      if (!trimmed) {
        flushList();
        continue;
      }

      // Headers
      if (trimmed.startsWith('### ')) {
        flushList();
        elements.push(html`<h4 key=${keyIdx++}>${parseInlineFormatting(trimmed.slice(4))}</h4>`);
        continue;
      }
      if (trimmed.startsWith('## ')) {
        flushList();
        elements.push(html`<h3 key=${keyIdx++}>${parseInlineFormatting(trimmed.slice(3))}</h3>`);
        continue;
      }

      // Unordered list items starting with '*' or '-'
      const ulMatch = line.match(/^(\s*)([*+-])\s+(.*)$/);
      if (ulMatch) {
        if (listType !== 'ul') {
          flushList();
          listType = 'ul';
        }
        listItems.push(ulMatch[3]);
        continue;
      }

      // Ordered list items starting with numbers '1.', '2.', etc.
      const olMatch = line.match(/^(\s*)(\d+)\.\s+(.*)$/);
      if (olMatch) {
        if (listType !== 'ol') {
          flushList();
          listType = 'ol';
        }
        listItems.push(olMatch[3]);
        continue;
      }

      // Regular paragraph
      flushList();
      elements.push(html`<p key=${keyIdx++}>${parseInlineFormatting(line)}</p>`);
    }

    flushList();
    if (inCodeBlock && codeContent.length > 0) {
      elements.push(html`<pre key=${keyIdx++}><code>${codeContent.join('\n')}</code></pre>`);
    }

    return elements;
  };

  // --- Render Login UI ---
  if (!token) {
    return html`
      <div class="login-view-container" style="display: flex; justify-content: center; align-items: center; min-height: 100vh; background-color: #0f172a; font-family: 'Plus Jakarta Sans', sans-serif;">
        <div class="modal-content" style="max-width: 400px; padding: 32px; border-radius: 16px; background: #1e293b; border: 1px solid rgba(255,255,255,0.08); box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.3);">
          <h2 style="text-align: center; margin-bottom: 24px; color: #f8fafc; font-weight: 700;">Đăng nhập Thư Viện Song Ngữ</h2>
          <form onSubmit=${async (e) => {
            e.preventDefault();
            setLoginError('');
            try {
              const res = await fetch(
                `/api/auth/login?username=${encodeURIComponent(loginUsername)}&password=${encodeURIComponent(loginPassword)}`,
                { method: 'POST', credentials: 'include' }
              );
              if (!res.ok) throw new Error('Sai tài khoản hoặc mật khẩu');
              const data = await res.json();
              persistAuthTokens(data, setToken);
              setIsAdmin(data.is_admin);
              setUsername(data.username);
            } catch (err) {
              setLoginError(err.message || 'Lỗi đăng nhập');
            }
          }}>
            <div style="margin-bottom: 16px;">
              <label style="display: block; margin-bottom: 8px; font-size: 14px; color: #94a3b8; font-weight: 500;">Tài khoản</label>
              <input type="text" style="width: 100%; padding: 10px 12px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); background: #0f172a; color: #f8fafc; outline: none;" value=${loginUsername} onInput=${(e) => setLoginUsername(e.target.value)} required />
            </div>
            <div style="margin-bottom: 24px;">
              <label style="display: block; margin-bottom: 8px; font-size: 14px; color: #94a3b8; font-weight: 500;">Mật khẩu</label>
              <input type="password" style="width: 100%; padding: 10px 12px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); background: #0f172a; color: #f8fafc; outline: none;" value=${loginPassword} onInput=${(e) => setLoginPassword(e.target.value)} required />
            </div>
            ${loginError && html`<div style="color: #ef4444; margin-bottom: 16px; font-size: 14px; text-align: center;">${loginError}</div>`}
            <button class="btn-primary" type="submit" style="width: 100%; padding: 12px; border-radius: 8px; font-weight: 600; cursor: pointer; background: #6366f1; border: none; color: white;">Đăng nhập</button>
          </form>
        </div>
      </div>
    `;
  }

  // --- Render Dashboard UI ---
  if (!activeBook) {
    return html`
      <div class="app-container">
        <header>
          <div class="header-container">
            <h1>Bilingual Digital Library</h1>
            <div class="profile-menu-container ${profileDropdownOpen ? 'open' : ''}">
              <button class="profile-trigger-btn" onClick=${(e) => {
                e.stopPropagation();
                setProfileDropdownOpen(!profileDropdownOpen);
              }}>
                <div class="profile-avatar">${username.slice(0, 2)}</div>
                <span>${username}</span>
              </button>
              <div class="profile-dropdown-menu" onClick=${(e) => e.stopPropagation()}>
                ${isAdmin && html`
                  <a href="/admin" class="profile-dropdown-item" target="_blank">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                      <rect x="3" y="3" width="7" height="9" rx="1"></rect>
                      <rect x="14" y="3" width="7" height="5" rx="1"></rect>
                      <rect x="14" y="12" width="7" height="9" rx="1"></rect>
                      <rect x="3" y="16" width="7" height="5" rx="1"></rect>
                    </svg>
                    <span>Admin Site</span>
                  </a>
                `}
                <button class="profile-dropdown-item" onClick=${() => {
                  setProfileDropdownOpen(false);
                  openSettings();
                }}>
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <circle cx="12" cy="12" r="3"></circle>
                    <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1-1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path>
                  </svg>
                  <span>Cấu hình Companion Agent</span>
                </button>
                <div style="height: 1px; background: rgba(255, 255, 255, 0.08); margin: 4px 0;"></div>
                <button class="profile-dropdown-item logout" onClick=${handleLogout}>
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"></path>
                    <polyline points="16 17 21 12 16 7"></polyline>
                    <line x1="21" y1="12" x2="9" y2="12"></line>
                  </svg>
                  <span>Đăng xuất</span>
                </button>
              </div>
            </div>
          </div>
        </header>

        <main class="dashboard-container">
          <div class="dashboard-title-section">
            <h2>Danh sách Tủ Sách Song Ngữ</h2>
            <span style="color: var(--text-muted); font-size: 14px;">Tổng cộng: ${sortedBooks.length} cuốn</span>
          </div>

          ${sortedBooks.length === 0
            ? html`
              <div class="empty-state" style="text-align: center; padding: 80px 20px; color: var(--text-muted); background: rgba(255, 255, 255, 0.02); border: 1px dashed rgba(255, 255, 255, 0.1); border-radius: 16px; margin-top: 20px; backdrop-filter: blur(10px);">
                <div style="font-size: 64px; margin-bottom: 20px;">📚</div>
                <h3 style="color: var(--text-main); font-size: 20px; font-weight: 600; margin-bottom: 10px;">Thư viện song ngữ trống</h3>
                <p style="max-width: 480px; margin-left: auto; margin-right: auto; line-height: 1.6; font-size: 14px;">
                  Hệ thống vừa được reset dữ liệu sạch sẽ. Vui lòng nhấn nút <strong style="color: var(--primary);">Admin Site</strong> phía trên thanh công cụ để truy cập trang quản trị và tải lên tệp sách <code>.bkb</code> của bạn!
                </p>
              </div>
            `
            : html`
              <div class="books-grid">
                ${paginatedBooks.map(book => {
                  const hasCover = !!book.cover;
                  const progress = getSavedProgress(book.slug);
                  const hasProgress = progress && progress.page > 1;
                  return html`
                    <div class="book-card" key=${book.slug} onClick=${() => {
                      if (progress) {
                        setActiveBook(book);
                        setPage(progress.page);
                        setViewMode(progress.viewMode || 'en');
                      } else {
                        setActiveBook(book);
                        setPage(1);
                        setViewMode('en');
                      }
                    }}>
                      <div class="book-card__cover-wrapper">
                        ${hasCover
                          ? html`<img class="book-card__cover-img" src=${book.cover} alt=${book.title} />`
                          : html`
                            <div class="book-card__cover-fallback">
                              <h4>${book.title}</h4>
                              <p>${book.author}</p>
                            </div>
                          `
                        }
                        ${hasProgress && html`
                          <div class="book-card__last-read">🕐 ${getRelativeTime(progress.lastRead)}</div>
                        `}
                      </div>
                      <div class="book-card__content">
                        <h3 class="book-card__title">${book.title}</h3>
                        <div class="book-card__author">Tác giả: ${book.author}</div>
                        <p class="book-card__desc">${book.description}</p>
                        <div class="book-card__footer">
                          <span>📖 ${hasProgress ? `${progress.page}/${book.pageCount} trang` : `${book.pageCount} trang`}</span>
                          <span class="book-card__badge">Bilingual</span>
                        </div>
                      </div>
                    </div>
                  `;
                })}
              </div>
            `
          }

          ${totalPages > 1 && html`
            <div class="pagination-container">
              <button class="nav-btn pagination-arrow" disabled=${clampedPage <= 1} onClick=${() => setCurrentPage(p => Math.max(1, p - 1))}>
                ◀
              </button>
              <span class="pagination-info">Trang ${clampedPage} / ${totalPages}</span>
              <button class="nav-btn pagination-arrow" disabled=${clampedPage >= totalPages} onClick=${() => setCurrentPage(p => Math.min(totalPages, p + 1))}>
                ▶
              </button>
            </div>
          `}
        </main>

        <footer>
          <p>© 2026 Bilingual Book Reader. Digital restoration crafted with ♥ by @thaonv795.</p>
        </footer>

        ${settingsOpen && renderSettingsModal()}
        ${popupConfig && renderPopupModal()}
      </div>
    `;
  }

  // --- Render Settings Modal ---
  function renderSettingsModal() {
    return html`
      <div class="modal-backdrop" onClick=${() => setSettingsOpen(false)}>
        <form class="modal-content modal-content--settings" onSubmit=${saveSettings} onClick=${(e) => e.stopPropagation()}>
          <div class="modal-header">
            <h3>Cấu hình Companion Agent & Voca</h3>
            <button class="nav-btn" type="button" onClick=${() => setSettingsOpen(false)}>✕</button>
          </div>
          <div class="modal-body">
            <section class="settings-section">
              <h4 class="settings-section__title">Companion Reader Agent</h4>
              <div class="settings-form-grid">
                <div class="form-group form-group--full">
                  <label class="form-label">API Provider</label>
                  <select class="form-select" value=${formProvider} onChange=${onProviderChange}>
                    <option value="openai">OpenAI (Official)</option>
                    <option value="gemini">Google Gemini (OpenAI compat)</option>
                    <option value="custom">Custom (Ollama / Local)</option>
                  </select>
                </div>

                <div class="form-group form-group--full">
                  <label class="form-label">API Base URL</label>
                  <input class="form-input" type="text" required value=${formBaseURL} onInput=${(e) => setFormBaseURL(e.target.value)} />
                </div>

                <div class="form-group">
                  <label class="form-label">API Key</label>
                  <input class="form-input" type="password" placeholder="Nhập API Key của bạn" value=${formApiKey} onInput=${(e) => setFormApiKey(e.target.value)} />
                </div>

                <div class="form-group">
                  <label class="form-label">Model Name</label>
                  <input class="form-input" type="text" required value=${formModel} onInput=${(e) => setFormModel(e.target.value)} />
                </div>
              </div>
            </section>

            <section class="settings-section">
              <h4 class="settings-section__title">Companion Voice (Realtime)</h4>
              <p class="settings-section__hint">Cấu hình cuộc gọi giọng nói trực tiếp (WebRTC).</p>
              <div class="settings-form-grid">
                <div class="form-group form-group--full">
                  <label class="form-label">Realtime API Key</label>
                  <input class="form-input" type="password" placeholder="Mặc định dùng chung API Key chính ở trên" value=${formRealtimeApiKey} onInput=${(e) => setFormRealtimeApiKey(e.target.value)} />
                </div>

                <div class="form-group">
                  <label class="form-label">Realtime Model Name</label>
                  <input class="form-input" type="text" placeholder="gpt-realtime-mini" value=${formRealtimeModel} onInput=${(e) => setFormRealtimeModel(e.target.value)} />
                </div>

                <div class="form-group">
                  <label class="form-label">AI Voice</label>
                  <select class="form-select" value=${formRealtimeVoice} onChange=${(e) => setFormRealtimeVoice(e.target.value)}>
                    <option value="alloy">Alloy (Mặc định)</option>
                    <option value="ash">Ash</option>
                    <option value="ballad">Ballad</option>
                    <option value="coral">Coral</option>
                    <option value="echo">Echo</option>
                    <option value="sage">Sage</option>
                    <option value="shimmer">Shimmer</option>
                    <option value="verse">Verse</option>
                  </select>
                </div>
              </div>
            </section>

            <section class="settings-section">
              <h4 class="settings-section__title">Voca Dictionary Bridge</h4>
              <p class="settings-section__hint">Dùng chung API Key / Model phía trên để tạo thẻ từ vựng và TTS phát âm.</p>
              <div class="settings-form-grid">
                <div class="form-group form-group--full">
                  <label class="form-label">Voca Bridge URL</label>
                  <input class="form-input" type="url" placeholder="https://voca-bridge.thaonv.online" value=${formVocaBridgeOrigin} onInput=${(e) => setFormVocaBridgeOrigin(e.target.value)} />
                </div>

                <div class="form-group form-group--full">
                  <label class="form-label">Voca API Token</label>
                  <input class="form-input" type="password" placeholder="Bearer token" value=${formVocaBridgeToken} onInput=${(e) => setFormVocaBridgeToken(e.target.value)} />
                </div>

                <div class="form-group">
                  <label class="form-label">TTS Endpoint (tùy chọn)</label>
                  <input class="form-input" type="url" placeholder="https://api.openai.com/v1/audio/speech" value=${formTtsEndpoint} onInput=${(e) => setFormTtsEndpoint(e.target.value)} />
                </div>

                <div class="form-group">
                  <label class="form-label">TTS Voice Model</label>
                  <input class="form-input" type="text" value=${formTtsModel} onInput=${(e) => setFormTtsModel(e.target.value)} />
                </div>
              </div>
            </section>

            <section class="settings-section">
              <h4 class="settings-section__title">Bố cục song ngữ</h4>
              <div class="layout-options-grid">
                <div class=${`layout-option-card ${formLayoutMode === 'en-vi' ? 'active' : ''}`} onClick=${() => setFormLayoutMode('en-vi')} title="English - Tiếng Việt (Trái - Phải)">
                  <div class="layout-preview preview-en-vi">
                    <span class="preview-badge badge-en">EN</span>
                    <span class="preview-badge badge-vi">VI</span>
                  </div>
                </div>

                <div class=${`layout-option-card ${formLayoutMode === 'vi-en' ? 'active' : ''}`} onClick=${() => setFormLayoutMode('vi-en')} title="Tiếng Việt - English (Trái - Phải)">
                  <div class="layout-preview preview-vi-en">
                    <span class="preview-badge badge-vi">VI</span>
                    <span class="preview-badge badge-en">EN</span>
                  </div>
                </div>

                <div class=${`layout-option-card ${formLayoutMode === 'en-over-vi' ? 'active' : ''}`} onClick=${() => setFormLayoutMode('en-over-vi')} title="English / Tiếng Việt (Trên - Dưới)">
                  <div class="layout-preview preview-en-over-vi">
                    <span class="preview-badge badge-en">EN</span>
                    <span class="preview-badge badge-vi">VI</span>
                  </div>
                </div>

                <div class=${`layout-option-card ${formLayoutMode === 'vi-over-en' ? 'active' : ''}`} onClick=${() => setFormLayoutMode('vi-over-en')} title="Tiếng Việt / English (Trên - Dưới)">
                  <div class="layout-preview preview-vi-over-en">
                    <span class="preview-badge badge-vi">VI</span>
                    <span class="preview-badge badge-en">EN</span>
                  </div>
                </div>
              </div>
            </section>
          </div>
          <div class="modal-footer">
            <button class="btn-secondary" type="button" onClick=${() => setSettingsOpen(false)}>Hủy</button>
            <button class="btn-primary" type="submit">Lưu Cấu Hình</button>
          </div>
        </form>
      </div>
    `;
  }

  // --- Render Custom Alert/Confirm Popup ---
  function renderPopupModal() {
    if (!popupConfig) return null;

    const { type, title, message, onConfirm, onCancel } = popupConfig;

    const handleConfirmClick = () => {
      setPopupConfig(null);
      if (onConfirm) onConfirm();
    };

    const handleCancelClick = () => {
      setPopupConfig(null);
      if (onCancel) onCancel();
    };

    return html`
      <div class="modal-backdrop" onClick=${handleCancelClick}>
        <div class="modal-content" style="max-width: 400px; animation: modalIn 0.2s ease-out;" onClick=${(e) => e.stopPropagation()}>
          <div class="modal-header" style="padding: 16px 20px;">
            <h3>${title || (type === 'confirm' ? 'Xác nhận' : 'Thông báo')}</h3>
            <button class="nav-btn" type="button" onClick=${handleCancelClick}>✕</button>
          </div>
          <div class="modal-body" style="padding: 20px; font-size: 14px; line-height: 1.5; color: var(--text-color);">
            ${message}
          </div>
          <div class="modal-footer" style="padding: 12px 20px;">
            ${type === 'confirm' && html`
              <button class="btn-secondary" style="padding: 8px 16px; border-radius: 8px;" type="button" onClick=${handleCancelClick}>Hủy</button>
            `}
            <button class="btn-primary" style="padding: 8px 16px; border-radius: 8px;" type="button" onClick=${handleConfirmClick}>Đồng ý</button>
          </div>
        </div>
      </div>
    `;
  }

  // --- Render Reader UI ---
  const padPage = (num) => String(num).padStart(4, '0');
  
  const enPageUrl = `books/${activeBook.slug}/output/en/page_${padPage(page)}.html`;
  const viPageUrl = `books/${activeBook.slug}/output/vi/page_${padPage(page)}.html`;

  return html`
    <div class="reader-view">
      <div class="reader-topbar">
        <div class="reader-topbar__left">
          <button class="btn-action" onClick=${() => setActiveBook(null)}>
            🏠 Library
          </button>
          <span class="reader-topbar__title">${activeBook.title}</span>
        </div>

        <div class="reader-nav">
          <button class="nav-btn" disabled=${page <= 1} onClick=${() => setPage(p => Math.max(1, p - 1))}>
            ◀
          </button>
          <span class="page-indicator">
            Trang
            <input class="page-input" type="number" min="1" max=${activeBook.pageCount} value=${page} 
              onChange=${(e) => {
                let val = parseInt(e.target.value, 10);
                if (isNaN(val) || val < 1) val = 1;
                if (val > activeBook.pageCount) val = activeBook.pageCount;
                setPage(val);
              }}
            />
            / ${activeBook.pageCount}
          </span>
          <button class="nav-btn" disabled=${page >= activeBook.pageCount} onClick=${() => setPage(p => Math.min(activeBook.pageCount, p + 1))}>
            ▶
          </button>
        </div>

        <div class="reader-topbar__right">
          <div class="view-modes">
            <button class=${`mode-btn ${viewMode === 'en' ? 'active' : ''}`} onClick=${() => setViewMode('en')} title="Tiếng Anh (Bản gốc)">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"></path>
                <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"></path>
              </svg>
              <span>EN</span>
            </button>
            <button class=${`mode-btn ${viewMode === 'vi' ? 'active' : ''}`} onClick=${() => setViewMode('vi')} title="Tiếng Việt (Bản dịch)">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"></path>
                <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"></path>
              </svg>
              <span>VI</span>
            </button>
            <button class=${`mode-btn ${viewMode === 'split' ? 'active' : ''}`} onClick=${() => setViewMode('split')} title="Song ngữ song song">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect>
                <line x1="12" y1="3" x2="12" y2="21"></line>
              </svg>
              <span>Song Ngữ</span>
            </button>
          </div>

          <button class=${`btn-icon ${chatOpen ? 'active' : ''}`} onClick=${() => setChatOpen(!chatOpen)} title="Companion Reader Agent">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path>
              <circle cx="9" cy="10" r="1"></circle>
              <circle cx="15" cy="10" r="1"></circle>
              <path d="M9 15h6"></path>
            </svg>
          </button>
          
          <button class="btn-icon" onClick=${openSettings} title="Cấu hình API Key">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <circle cx="12" cy="12" r="3"></circle>
              <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1-1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path>
            </svg>
          </button>
          
          <div class="profile-menu-container ${profileDropdownOpen ? 'open' : ''}">
            <button class="profile-trigger-btn" style="padding: 6px 12px; border-radius: 16px;" onClick=${(e) => {
              e.stopPropagation();
              setProfileDropdownOpen(!profileDropdownOpen);
            }}>
              <div class="profile-avatar" style="width: 20px; height: 20px; font-size: 10px;">${username.slice(0, 2)}</div>
              <span style="font-size: 13px;">${username}</span>
            </button>
            <div class="profile-dropdown-menu" onClick=${(e) => e.stopPropagation()}>
              ${isAdmin && html`
                <a href="/admin" class="profile-dropdown-item" target="_blank">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <rect x="3" y="3" width="7" height="9" rx="1"></rect>
                    <rect x="14" y="3" width="7" height="5" rx="1"></rect>
                    <rect x="14" y="12" width="7" height="9" rx="1"></rect>
                    <rect x="3" y="16" width="7" height="5" rx="1"></rect>
                  </svg>
                  <span>Admin Site</span>
                </a>
              `}
              <button class="profile-dropdown-item" onClick=${() => {
                setProfileDropdownOpen(false);
                openSettings();
              }}>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <circle cx="12" cy="12" r="3"></circle>
                  <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1-1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path>
                </svg>
                <span>Cấu hình Companion Agent</span>
              </button>
              <div style="height: 1px; background: rgba(255, 255, 255, 0.08); margin: 4px 0;"></div>
              <button class="profile-dropdown-item logout" onClick=${handleLogout}>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"></path>
                  <polyline points="16 17 21 12 16 7"></polyline>
                  <line x1="21" y1="12" x2="9" y2="12"></line>
                </svg>
                <span>Đăng xuất</span>
              </button>
            </div>
          </div>
        </div>
      </div>

      <div
        class=${`reader-workspace ${chatOpen ? 'chat-open' : ''}`}
        style=${chatOpen ? { '--chat-width': `${chatWidth}px` } : {}}
      >
        <div class=${`reader-panes layout-${layoutMode}`}>
          
          <!-- English Pane -->
          ${(viewMode === 'en' || viewMode === 'split') && html`
            <div class="reader-pane" id="en-pane">
              <span class="pane-label">EN</span>
              <div class="iframe-wrapper">
                <iframe class="reader-iframe en-pane-iframe" src=${enPageUrl} key=${`en-${page}`} onLoad=${handleIframeLoad} scrolling="no" />
              </div>
            </div>
          `}

          <!-- Vietnamese Pane -->
          ${(viewMode === 'vi' || viewMode === 'split') && html`
            <div class="reader-pane" id="vi-pane">
              <span class="pane-label">VI</span>
              <div class="iframe-wrapper">
                <iframe class="reader-iframe vi-pane-iframe" src=${viPageUrl} key=${`vi-${page}`} onLoad=${handleIframeLoad} scrolling="no" />
              </div>
            </div>
          `}
        </div>

        <!-- Chat Sidebar Drawer -->
        <div class=${`chat-sidebar ${isResizing ? 'is-resizing' : ''}`} style=${chatOpen ? { width: `${chatWidth}px` } : { width: '0px', borderLeft: 'none', overflow: 'hidden' }}>
          <!-- Resize Handle -->
          <div class="chat-resize-handle" onMouseDown=${startResizing}></div>

          <div class="chat-header">
            <span class="chat-header__title">
              🤖 Companion Reader Agent
              <span class="chat-header__badge">Context Active</span>
            </span>
            <div style="display: flex; gap: 8px; align-items: center;">
              <button class=${`nav-btn chat-header-mic-btn ${realtimeVoiceActive ? 'active ' + realtimeState : ''}`} 
                onClick=${realtimeVoiceActive ? stopRealtimeVoice : startRealtimeVoice} 
                title=${realtimeVoiceActive ? 'Tắt Voice Conversation' : 'Bật Voice Conversation'}
              >
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"></path>
                  <path d="M19 10v2a7 7 0 0 1-14 0v-2"></path>
                  <line x1="12" y1="19" x2="12" y2="23"></line>
                  <line x1="8" y1="23" x2="16" y2="23"></line>
                </svg>
              </button>
              ${messages.length > 0 && !realtimeVoiceActive && html`
                <button class="nav-btn reload-chat-btn" onClick=${handleClearActiveChat} title="Làm mới phiên chat">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M23 4v6h-6"></path>
                    <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"></path>
                  </svg>
                </button>
              `}
              <button class="nav-btn" onClick=${() => setChatOpen(false)}>✕</button>
            </div>
          </div>

          ${realtimeVoiceActive 
            ? html`
              <!-- Realtime Voice Mode Active Layout -->
              <div class="voice-overlay">
                <div class="voice-status">
                  <span class=${`status-dot ${realtimeState}`}></span>
                  <span class="status-text">
                    ${realtimeState === 'connecting' 
                      ? 'Đang kết nối Realtime...' 
                      : realtimeState === 'live' 
                        ? 'Đang kết nối trực tiếp (Live)' 
                        : realtimeState === 'error' 
                          ? `Lỗi: ${realtimeError || 'Không thể kết nối'}` 
                          : 'Đang ngoại tuyến'}
                  </span>
                </div>

                <div class="voice-visualizer">
                  <div class="voice-orb">
                    <div class=${`voice-pulse-ring ring-1 ${realtimeState}`}></div>
                    <div class=${`voice-pulse-ring ring-2 ${realtimeState}`}></div>
                    <div class=${`voice-pulse-ring ring-3 ${realtimeState}`}></div>
                    <div class=${`voice-icon-inner ${realtimeState}`}>
                      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                        <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"></path>
                        <path d="M19 10v2a7 7 0 0 1-14 0v-2"></path>
                        <line x1="12" y1="19" x2="12" y2="23"></line>
                        <line x1="8" y1="23" x2="16" y2="23"></line>
                      </svg>
                    </div>
                  </div>
                  <div class=${`voice-wave-bars ${realtimeState === 'live' ? 'active' : ''}`}>
                    <span class="bar"></span>
                    <span class="bar"></span>
                    <span class="bar"></span>
                    <span class="bar"></span>
                    <span class="bar"></span>
                  </div>
                </div>

                <div class="voice-captions">
                  ${realtimeUserTranscript && html`
                    <div class="voice-caption-bubble user">
                      <span class="caption-label">Bạn nói:</span>
                      <p class="caption-text">${realtimeUserTranscript}</p>
                    </div>
                  `}
                  <div class="voice-caption-bubble assistant">
                    <span class="caption-label">Companion Reader Agent:</span>
                    <p class="caption-text">${realtimeCaption || 'Hãy nói gì đó qua micro...'}</p>
                  </div>
                </div>

                <button class="voice-end-btn" onClick=${stopRealtimeVoice}>
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" style="margin-right: 8px;">
                    <rect x="4" y="4" width="16" height="16" rx="2" ry="2" fill="currentColor"></rect>
                  </svg>
                  Kết thúc hội thoại
                </button>
              </div>
            `
            : html`
              <!-- Messages scrollable area -->
              <div class="chat-messages">
                ${messages.map((msg, idx) => html`
                  <div class=${`chat-bubble ${msg.role === 'user' ? 'bubble-user' : 'bubble-assistant'} ${msg.pending ? 'pending' : ''}`} key=${idx}>
                    ${msg.pending 
                      ? html`
                        <div style="display: flex; align-items: center; gap: 8px; font-size: 13px; color: var(--text-muted);">
                          <span>Đang trả lời</span>
                          <div class="typing-indicator">
                            <span></span>
                            <span></span>
                            <span></span>
                          </div>
                        </div>
                      `
                      : renderMessageContent(msg.content)
                    }
                  </div>
                `)}
                <div ref=${messagesEndRef} />
              </div>

              <!-- Quick Actions Prompt Toolbar -->
              <div class="chat-quick-actions">
                <button class="quick-prompt-btn" onClick=${() => handleQuickPrompt('Tóm tắt ngắn gọn nội dung trang này.')}>
                  📝 Tóm tắt trang
                </button>
                ${suggestedPrompts.map((item, idx) => html`
                  <button key=${idx} class="quick-prompt-btn" onClick=${() => handleQuickPrompt(item.prompt)}>
                    ${item.icon || '❓'} ${item.title}
                  </button>
                `)}
              </div>

              <!-- Input Composer -->
              <div class="chat-composer">
                <div class="chat-composer-container">
                  <textarea class="chat-input" 
                    placeholder="Hỏi về trang này hoặc toàn bộ sách..." 
                    value=${chatInput}
                    onInput=${(e) => setChatInput(e.target.value)}
                    onKeyDown=${(e) => {
                      if (e.key === 'Enter' && !e.shiftKey) {
                        e.preventDefault();
                        sendChatMessage();
                      }
                    }}
                  />
                  <div class="chat-composer-actions">
                    <div style="display: flex; align-items: center; gap: 8px;">
                      <span class="chat-char-counter">${chatInput.length} ký tự</span>
                      <button class=${`chat-mic-btn ${isRecordingMic ? 'recording' : ''}`} onClick=${toggleSpeechRecognition} title="Nhập liệu bằng giọng nói" style="background: none; border: none; cursor: pointer; color: ${isRecordingMic ? '#ef4444' : '#64748b'}; display: flex; align-items: center; justify-content: center; padding: 4px; border-radius: 4px; transition: color 0.2s;">
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
                          <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"></path>
                          <path d="M19 10v2a7 7 0 0 1-14 0v-2"></path>
                          <line x1="12" y1="19" x2="12" y2="23"></line>
                          <line x1="8" y1="23" x2="16" y2="23"></line>
                        </svg>
                      </button>
                    </div>
                    ${chatPending 
                      ? html`
                        <button class="chat-send-btn chat-cancel-btn" onClick=${handleCancelChat} title="Hủy phản hồi">
                          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                            <rect x="4" y="4" width="16" height="16" rx="2" ry="2" fill="currentColor"></rect>
                          </svg>
                        </button>
                      `
                      : html`
                        <button class="chat-send-btn" disabled=${!chatInput.trim()} onClick=${() => sendChatMessage()}>
                          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                            <line x1="22" y1="2" x2="11" y2="13"></line>
                            <polygon points="22 2 15 22 11 13 2 9 22 2"></polygon>
                          </svg>
                        </button>
                      `
                    }
                  </div>
                </div>
              </div>
            `
          }
        </div>
      </div>

      ${settingsOpen && renderSettingsModal()}
      ${popupConfig && renderPopupModal()}
    </div>
  `;
}

// --- Bilingual Sentence Highlight Sync Helpers ---

function splitIntoSentences(text) {
  if (!text) return [];
  
  const sentences = [];
  let currentStart = 0;
  
  const boundaryRegex = /([.!?])(\s+|$)/g;
  let match;
  
  const abbrevs = [
    'mr', 'mrs', 'dr', 'ms', 'prof', 'sr', 'jr', 'vs', 'etc', 'eg', 'ie', 'al',
    'st', 'av', 'rd', 'capt', 'gen', 'col', 'lt', 'sgt', 'rep', 'sen', 'oct', 'nov', 'dec',
    'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'tp', 'ts', 'ths', 'gs', 'hcm'
  ];
  
  while ((match = boundaryRegex.exec(text)) !== null) {
    const boundaryIdx = match.index;
    
    const precedingText = text.substring(currentStart, boundaryIdx);
    const lastWordMatch = precedingText.match(/(\b\w+)$/);
    const lastWord = lastWordMatch ? lastWordMatch[1].toLowerCase() : '';
    
    if (abbrevs.includes(lastWord)) {
      continue;
    }
    
    // Split including exact boundary punctuation and its trailing whitespace
    const sentenceEnd = boundaryIdx + 1 + match[2].length;
    const sentenceText = text.substring(currentStart, sentenceEnd);
    if (sentenceText.length > 0) {
      sentences.push(sentenceText);
    }
    currentStart = sentenceEnd;
  }
  
  if (currentStart < text.length) {
    const remaining = text.substring(currentStart);
    if (remaining.length > 0) {
      sentences.push(remaining);
    }
  }
  
  return sentences;
}

function segmentParagraph(pElement, pIdx) {
  const text = pElement.textContent;
  const sentences = splitIntoSentences(text);
  
  if (sentences.length <= 1) {
    const span = pElement.ownerDocument.createElement('span');
    span.className = 'sentence-node';
    span.dataset.sentenceId = `p-${pIdx}-s-0`;
    while (pElement.firstChild) {
      span.appendChild(pElement.firstChild);
    }
    pElement.appendChild(span);
    return;
  }
  
  const sentenceSpans = sentences.map((sText, sIdx) => {
    const span = pElement.ownerDocument.createElement('span');
    span.className = 'sentence-node';
    span.dataset.sentenceId = `p-${pIdx}-s-${sIdx}`;
    return span;
  });
  
  let currentSentenceIdx = 0;
  let currentSentenceRemainingLen = sentences[0].length;
  
  const childNodes = Array.from(pElement.childNodes);
  pElement.innerHTML = '';
  
  childNodes.forEach(node => {
    if (node.nodeType === 3) { // Text Node
      let nodeText = node.textContent;
      while (nodeText.length > 0 && currentSentenceIdx < sentences.length) {
        if (nodeText.length <= currentSentenceRemainingLen) {
          const textNode = pElement.ownerDocument.createTextNode(nodeText);
          sentenceSpans[currentSentenceIdx].appendChild(textNode);
          currentSentenceRemainingLen -= nodeText.length;
          nodeText = '';
        } else {
          const part = nodeText.substring(0, currentSentenceRemainingLen);
          const textNode = pElement.ownerDocument.createTextNode(part);
          sentenceSpans[currentSentenceIdx].appendChild(textNode);
          
          nodeText = nodeText.substring(currentSentenceRemainingLen);
          
          currentSentenceIdx++;
          if (currentSentenceIdx < sentences.length) {
            currentSentenceRemainingLen = sentences[currentSentenceIdx].length;
          }
        }
      }
    } else if (node.nodeType === 1) { // Element Node
      sentenceSpans[currentSentenceIdx].appendChild(node);
      currentSentenceRemainingLen -= node.textContent.length;
      if (currentSentenceRemainingLen <= 0 && currentSentenceIdx < sentences.length - 1) {
        currentSentenceIdx++;
        currentSentenceRemainingLen = sentences[currentSentenceIdx].length;
      }
    }
  });
  
  sentenceSpans.forEach(span => {
    if (span.textContent.length > 0) {
      pElement.appendChild(span);
    }
  });
}

function segmentDocSentences(doc) {
  const article = doc.querySelector('article') || doc.body;
  if (!article) return;
  
  const paragraphs = article.querySelectorAll(PARAGRAPH_SELECTOR);
  paragraphs.forEach((p, idx) => {
    if (!p.querySelector('.sentence-node')) {
      segmentParagraph(p, idx);
    }
  });
}

function injectHighlightCSS(doc, isEnglish) {
  if (doc.getElementById('bilingual-highlight-style')) return;
  const style = doc.createElement('style');
  style.id = 'bilingual-highlight-style';
  
  const highlightColor = isEnglish 
    ? 'rgba(56, 189, 248, 0.18)'
    : 'rgba(250, 204, 21, 0.20)';
    
  const hoverColor = isEnglish
    ? 'rgba(56, 189, 248, 0.08)'
    : 'rgba(250, 204, 21, 0.08)';

  style.textContent = `
    html {
      background-color: #F9F7F1 !important;
    }
    body, body.book-standalone {
      background-color: #F9F7F1 !important;
      color: #333333 !important;
    }
    main, article, .prose-page {
      background-color: transparent !important;
      color: inherit !important;
    }
    .book-page, .book-page--sheet, .sheet-flow {
      background-color: transparent !important;
    }
    div, p, h1, h2, h3, h4, h5, h6, ul, ol, li {
      background-color: transparent !important;
      color: inherit !important;
    }
    .sentence-node {
      transition: background-color 0.2s ease;
      border-radius: 3px;
      cursor: pointer;
      display: inline;
    }
    .sentence-node:hover {
      background-color: ${hoverColor};
    }
    .sentence-node.highlight-sync {
      background-color: ${highlightColor} !important;
    }
    mark.reader-highlight {
      border-radius: 3px;
      padding: 0 1px;
      cursor: pointer;
      position: relative;
      color: inherit;
      box-decoration-break: clone;
      -webkit-box-decoration-break: clone;
    }
    mark.reader-highlight[data-has-note="true"]::after {
      content: '';
      position: absolute;
      top: -3px;
      right: -3px;
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: #2563eb;
      border: 1px solid #fff;
    }
    mark.reader-highlight--pulse {
      animation: readerHighlightPulse 1.2s ease;
    }
    @keyframes readerHighlightPulse {
      0%, 100% { box-shadow: 0 0 0 0 rgba(37, 99, 235, 0); }
      50% { box-shadow: 0 0 0 4px rgba(37, 99, 235, 0.35); }
    }
    .reader-highlight-toolbar {
      position: fixed;
      z-index: 9999;
      transform: translate(-50%, -100%);
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 5px 7px;
      background: rgba(17, 24, 39, 0.92);
      backdrop-filter: blur(12px);
      border: 1px solid rgba(255, 255, 255, 0.12);
      border-radius: 10px;
      box-shadow: 0 6px 20px rgba(0, 0, 0, 0.35);
      animation: readerToolbarIn 0.15s ease;
    }
    .reader-highlight-toolbar__colors {
      display: flex;
      gap: 4px;
    }
    .reader-highlight-toolbar__color {
      width: 18px;
      height: 18px;
      border-radius: 50%;
      border: 1.5px solid rgba(255, 255, 255, 0.3);
      cursor: pointer;
      padding: 0;
    }
    .reader-highlight-toolbar__color:hover {
      transform: scale(1.1);
    }
    .reader-highlight-toolbar__icon {
      width: 22px;
      height: 22px;
      border-radius: 6px;
      border: 1px solid rgba(255, 255, 255, 0.1);
      background: rgba(255, 255, 255, 0.08);
      font-size: 11px;
      cursor: pointer;
      padding: 0;
      display: inline-flex;
      align-items: center;
      justify-content: center;
    }
    .reader-highlight-toolbar__icon:hover {
      background: rgba(255, 255, 255, 0.16);
    }
    .reader-highlight-sticky {
      position: fixed;
      z-index: 9999;
      width: 168px;
      min-height: 68px;
      background: linear-gradient(160deg, #fef9c3 0%, #fde68a 55%, #fcd34d 100%);
      border: 1px solid rgba(180, 130, 0, 0.35);
      border-radius: 1px 1px 1px 0;
      box-shadow: 1px 2px 0 rgba(180, 130, 0, 0.15), 3px 5px 12px rgba(0, 0, 0, 0.2);
      padding: 8px 8px 4px;
      transform: rotate(-1.5deg);
      animation: readerStickyIn 0.2s ease;
    }
    .reader-highlight-sticky__input {
      width: 100%;
      min-height: 48px;
      background: transparent;
      border: none;
      resize: none;
      font-family: 'Segoe Print', 'Comic Sans MS', cursive, sans-serif;
      font-size: 12px;
      line-height: 1.45;
      color: #422006;
      outline: none;
      padding: 0;
    }
    .reader-highlight-sticky__input::placeholder {
      color: rgba(66, 32, 6, 0.45);
    }
    .reader-highlight-sticky__footer {
      display: flex;
      justify-content: flex-end;
      gap: 2px;
      margin-top: 2px;
    }
    .reader-highlight-sticky__btn {
      background: transparent;
      border: none;
      width: 20px;
      height: 20px;
      border-radius: 4px;
      font-size: 11px;
      color: rgba(66, 32, 6, 0.55);
      cursor: pointer;
      padding: 0;
    }
    .reader-highlight-sticky__btn:hover {
      background: rgba(66, 32, 6, 0.08);
      color: #422006;
    }
    .reader-highlight-sticky__btn--save {
      font-weight: 700;
      color: rgba(66, 32, 6, 0.75);
    }
    @keyframes readerToolbarIn {
      from { opacity: 0; transform: translate(-50%, calc(-100% + 4px)); }
      to { opacity: 1; transform: translate(-50%, -100%); }
    }
    @keyframes readerStickyIn {
      from { opacity: 0; transform: rotate(-1.5deg) scale(0.92); }
      to { opacity: 1; transform: rotate(-1.5deg) scale(1); }
    }
    .prose-page p, .prose-page li, .prose-page blockquote,
    .prose-page .section-title, .prose-page .action-header, .prose-page .action-title,
    .prose-page h1, .prose-page h2, .prose-page h3, .prose-page h4, .prose-page h5, .prose-page h6,
    .sentence-node {
      user-select: text;
      -webkit-user-select: text;
    }
    ${getVocaLookupPanelCss()}
  `;
  doc.head.appendChild(style);
}

function getParagraphs(doc) {
  const article = doc.querySelector('article') || doc.body;
  return Array.from(article.querySelectorAll(PARAGRAPH_SELECTOR));
}

function getSelectionInfo(doc, selection) {
  if (!selection || selection.isCollapsed) return null;
  const text = selection.toString().trim();
  if (!text) return null;

  const range = selection.getRangeAt(0);
  let container = range.commonAncestorContainer;
  if (container.nodeType === 3) container = container.parentElement;
  const paragraph = container.closest(PARAGRAPH_SELECTOR);
  if (!paragraph) return null;

  const paragraphs = getParagraphs(doc);
  const paragraphIndex = paragraphs.indexOf(paragraph);
  if (paragraphIndex === -1) return null;

  const preRange = doc.createRange();
  preRange.selectNodeContents(paragraph);
  preRange.setEnd(range.startContainer, range.startOffset);
  const startOffset = preRange.toString().length;
  const endOffset = startOffset + range.toString().length;

  return { paragraphIndex, startOffset, endOffset, text: range.toString() };
}

function wrapTextRange(doc, paragraph, startOffset, endOffset, highlightData) {
  const walker = doc.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
  let charCount = 0;
  let startNode = null;
  let startNodeOffset = 0;
  let endNode = null;
  let endNodeOffset = 0;

  while (walker.nextNode()) {
    const node = walker.currentNode;
    const nodeLen = node.textContent.length;
    if (startNode === null && charCount + nodeLen > startOffset) {
      startNode = node;
      startNodeOffset = startOffset - charCount;
    }
    if (endNode === null && charCount + nodeLen >= endOffset) {
      endNode = node;
      endNodeOffset = endOffset - charCount;
      break;
    }
    charCount += nodeLen;
  }

  if (!startNode || !endNode) return false;

  const range = doc.createRange();
  range.setStart(startNode, startNodeOffset);
  range.setEnd(endNode, endNodeOffset);

  const mark = doc.createElement('mark');
  mark.className = 'reader-highlight';
  mark.dataset.highlightId = highlightData.id;
  mark.style.backgroundColor = highlightData.color;
  if (highlightData.note) {
    mark.dataset.hasNote = 'true';
    mark.title = highlightData.note;
  }

  try {
    range.surroundContents(mark);
  } catch (e) {
    const contents = range.extractContents();
    mark.appendChild(contents);
    range.insertNode(mark);
  }
  return true;
}

function applyStoredHighlights(doc, slug, pageNum, lang) {
  const highlights = loadHighlights(slug)
    .filter(h => h.page === pageNum && h.lang === lang)
    .sort((a, b) => {
      if (a.paragraphIndex !== b.paragraphIndex) {
        return a.paragraphIndex - b.paragraphIndex;
      }
      return b.startOffset - a.startOffset;
    });

  const paragraphs = getParagraphs(doc);
  highlights.forEach(h => {
    const paragraph = paragraphs[h.paragraphIndex];
    if (!paragraph) return;
    wrapTextRange(doc, paragraph, h.startOffset, h.endOffset, h);
  });
}

function reapplyHighlightsInIframes(slug, pageNum, lang) {
  const selector = lang === 'en' ? '.en-pane-iframe' : '.vi-pane-iframe';
  const iframe = document.querySelector(selector);
  if (!iframe?.contentDocument) return;
  const doc = iframe.contentDocument;
  removeReaderHighlightUI(doc);
  doc.querySelectorAll('mark.reader-highlight').forEach(el => {
    const parent = el.parentNode;
    while (el.firstChild) parent.insertBefore(el.firstChild, el);
    parent.removeChild(el);
  });
  segmentDocSentences(doc);
  applyStoredHighlights(doc, slug, pageNum, lang);
}

function removeReaderHighlightUI(doc) {
  if (!doc) return;
  doc.querySelectorAll('.reader-highlight-toolbar, .reader-highlight-sticky').forEach(el => el.remove());
  removeVocaLookupPanel(doc);
}

function removeAllReaderHighlightUI() {
  document.querySelectorAll('.reader-iframe').forEach(iframe => {
    if (iframe.contentDocument) removeReaderHighlightUI(iframe.contentDocument);
  });
}

function showReaderStickyNote(doc, anchorRect, options) {
  doc.querySelectorAll('.reader-highlight-sticky').forEach(el => el.remove());

  const noteEl = doc.createElement('div');
  noteEl.className = 'reader-highlight-sticky';
  const noteWidth = 168;
  let noteX = anchorRect.right + 6;
  if (noteX + noteWidth > doc.documentElement.clientWidth - 8) {
    noteX = Math.max(8, anchorRect.left - noteWidth - 6);
  }
  noteEl.style.left = `${noteX}px`;
  noteEl.style.top = `${anchorRect.top}px`;

  const textarea = doc.createElement('textarea');
  textarea.className = 'reader-highlight-sticky__input';
  textarea.placeholder = 'Ghi chú...';
  textarea.value = options.note || '';

  const footer = doc.createElement('div');
  footer.className = 'reader-highlight-sticky__footer';

  const cancelBtn = doc.createElement('button');
  cancelBtn.className = 'reader-highlight-sticky__btn';
  cancelBtn.type = 'button';
  cancelBtn.title = 'Hủy';
  cancelBtn.textContent = '✕';
  cancelBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    noteEl.remove();
  });

  const saveBtn = doc.createElement('button');
  saveBtn.className = 'reader-highlight-sticky__btn reader-highlight-sticky__btn--save';
  saveBtn.type = 'button';
  saveBtn.title = 'Lưu';
  saveBtn.textContent = '✓';

  const handleSave = () => {
    const text = textarea.value;
    if (options.mode === 'create') {
      highlightAppContext?.createHighlight?.(options.selectionInfo, options.lang, options.color, text);
    } else {
      highlightAppContext?.updateHighlight?.(options.highlightId, { note: text });
    }
    noteEl.remove();
  };

  saveBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    handleSave();
  });

  textarea.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Escape') noteEl.remove();
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      handleSave();
    }
  });

  footer.appendChild(cancelBtn);
  footer.appendChild(saveBtn);
  noteEl.appendChild(textarea);
  noteEl.appendChild(footer);
  noteEl.addEventListener('mousedown', (e) => e.stopPropagation());
  noteEl.addEventListener('mouseup', (e) => e.stopPropagation());
  doc.body.appendChild(noteEl);
  textarea.focus();
}

function showReaderHighlightToolbar(doc, anchorRect, options) {
  removeReaderHighlightUI(doc);

  const existing = options.highlightId && highlightAppContext?.slug
    ? loadHighlights(highlightAppContext.slug).find(h => h.id === options.highlightId)
    : null;

  const toolbar = doc.createElement('div');
  toolbar.className = 'reader-highlight-toolbar';
  toolbar.style.left = `${anchorRect.left + anchorRect.width / 2}px`;
  toolbar.style.top = `${anchorRect.top - 6}px`;

  const colors = doc.createElement('div');
  colors.className = 'reader-highlight-toolbar__colors';

  HIGHLIGHT_COLORS.forEach(c => {
    const btn = doc.createElement('button');
    btn.type = 'button';
    btn.className = 'reader-highlight-toolbar__color';
    btn.style.backgroundColor = c.value;
    btn.title = c.label;
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      if (options.mode === 'create') {
        highlightAppContext?.createHighlight?.(options.selectionInfo, options.lang, c.value);
      } else {
        highlightAppContext?.updateHighlight?.(options.highlightId, { color: c.value });
      }
    });
    colors.appendChild(btn);
  });
  toolbar.appendChild(colors);

  const noteBtn = doc.createElement('button');
  noteBtn.type = 'button';
  noteBtn.className = 'reader-highlight-toolbar__icon';
  noteBtn.title = 'Ghi chú';
  noteBtn.textContent = '📝';
  noteBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    toolbar.remove();
    showReaderStickyNote(doc, anchorRect, {
      mode: options.mode,
      lang: options.lang,
      selectionInfo: options.selectionInfo,
      highlightId: options.highlightId,
      color: existing?.color || HIGHLIGHT_COLORS[0].value,
      note: existing?.note || '',
    });
  });
  toolbar.appendChild(noteBtn);

  const text = options.selectionInfo?.text || existing?.text;
  if (options.lang === 'en' && text) {
    const lookupBtn = doc.createElement('button');
    lookupBtn.type = 'button';
    lookupBtn.className = 'reader-highlight-toolbar__icon';
    lookupBtn.title = 'Tra cứu Voca';
    lookupBtn.textContent = '📖';
    lookupBtn.addEventListener('click', async (e) => {
      e.stopPropagation();
      toolbar.remove();
      const word = cleanWord(text);
      if (!word) return;
      try {
        const result = await lookupWord(word);
        if (result.found) {
          showVocaLookupResults(doc, anchorRect, word, result);
        } else {
          showVocaNotFoundPanel(doc, anchorRect, word);
        }
      } catch (err) {
        showVocaError(err instanceof Error ? err.message : 'Lookup failed.');
      }
    });
    toolbar.appendChild(lookupBtn);
  }

  if (options.mode === 'edit') {
    const delBtn = doc.createElement('button');
    delBtn.type = 'button';
    delBtn.className = 'reader-highlight-toolbar__icon';
    delBtn.title = 'Xóa';
    delBtn.textContent = '🗑';
    delBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      highlightAppContext?.deleteHighlight?.(options.highlightId);
    });
    toolbar.appendChild(delBtn);
  }

  toolbar.addEventListener('mousedown', (e) => e.stopPropagation());
  toolbar.addEventListener('mouseup', (e) => e.stopPropagation());
  doc.body.appendChild(toolbar);
}

function highlightSentenceAcrossIframes(sentenceId) {
  const enIframe = document.querySelector('.en-pane-iframe');
  const viIframe = document.querySelector('.vi-pane-iframe');
  
  [enIframe, viIframe].forEach(iframe => {
    if (iframe && iframe.contentDocument) {
      const doc = iframe.contentDocument;
      doc.querySelectorAll('.sentence-node.highlight-sync').forEach(el => {
        el.classList.remove('highlight-sync');
      });
      const targetNode = doc.querySelector(`.sentence-node[data-sentence-id="${sentenceId}"]`);
      if (targetNode) {
        targetNode.classList.add('highlight-sync');
      }
    }
  });
}

function clearAllHighlights() {
  const enIframe = document.querySelector('.en-pane-iframe');
  const viIframe = document.querySelector('.vi-pane-iframe');
  
  [enIframe, viIframe].forEach(iframe => {
    if (iframe && iframe.contentDocument) {
      iframe.contentDocument.querySelectorAll('.sentence-node.highlight-sync').forEach(el => {
        el.classList.remove('highlight-sync');
      });
    }
  });
}

function registerIframeHighlightListeners(iframeWin, doc, iframeEl, lang) {
  doc.addEventListener('mousedown', (e) => {
    if (e.target.closest('mark.reader-highlight, .reader-highlight-toolbar, .reader-highlight-sticky, .voca-lookup-panel')) return;
    removeReaderHighlightUI(doc);
  });

  doc.addEventListener('mouseup', (e) => {
    if (e.target.closest('.reader-highlight-toolbar, .reader-highlight-sticky, .voca-lookup-panel')) return;

    setTimeout(() => {
      if (e.target.closest('.reader-highlight-toolbar, .reader-highlight-sticky, .voca-lookup-panel')) return;

      const selection = iframeWin.getSelection();
      const selectedText = selection.toString().trim();
      const clickedMark = e.target.closest('mark.reader-highlight');

      if (clickedMark) {
        const highlightId = clickedMark.dataset.highlightId;
        const rect = clickedMark.getBoundingClientRect();
        showReaderHighlightToolbar(doc, rect, {
          mode: 'edit',
          lang,
          highlightId,
        });
        if (highlightAppContext?.slug) {
          const existing = loadHighlights(highlightAppContext.slug).find(h => h.id === highlightId);
          if (existing?.note) {
            showReaderStickyNote(doc, rect, {
              mode: 'edit',
              highlightId,
              lang,
              note: existing.note,
            });
          }
        }
        selection.removeAllRanges();
        return;
      }

      if (selectedText.length > 2) {
        const selectionInfo = getSelectionInfo(doc, selection);
        if (selectionInfo) {
          const rect = selection.getRangeAt(0).getBoundingClientRect();
          showReaderHighlightToolbar(doc, rect, {
            mode: 'create',
            lang,
            selectionInfo,
          });
        }
        return;
      }

      let sentenceNode = null;
      if (selectedText.length > 0) {
        const node = selection.anchorNode;
        if (node) {
          sentenceNode = node.parentElement.closest('.sentence-node');
        }
      } else {
        sentenceNode = e.target.closest('.sentence-node');
      }

      if (sentenceNode) {
        const sentenceId = sentenceNode.dataset.sentenceId;
        highlightSentenceAcrossIframes(sentenceId);
      } else {
        removeReaderHighlightUI(doc);
        clearAllHighlights();
      }
    }, 10);
  });
}

// Render the application to root body element
render(html`<${App} />`, document.body);
