'use client'

import React from 'react'
import {
  Box,
  Button,
  Text,
  Alert,
  AlertIcon,
  AlertTitle,
  AlertDescription,
  Spinner,
  VStack,
  useColorModeValue,
} from '@chakra-ui/react'

// Declare dcv as a global variable for TypeScript
declare global {
  interface Window {
    dcv: any
  }
}

// Error Boundary for DCV DOM cleanup errors
class DCVErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { hasError: boolean }
> {
  constructor(props: { children: React.ReactNode }) {
    super(props)
    this.state = { hasError: false }
  }

  static getDerivedStateFromError(error: Error) {
    // Check if it's a DOM cleanup error we can safely ignore
    if (error.message && (
      error.message.includes('removeChild') ||
      error.message.includes('The node to be removed is not a child of this node')
    )) {
      console.log('Caught and handled DCV DOM cleanup error:', error.message)
      return { hasError: false } // Don't show error UI for these
    }
    return { hasError: true }
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
    if (error.message && (
      error.message.includes('removeChild') ||
      error.message.includes('The node to be removed is not a child of this node')
    )) {
      console.log('DCV DOM cleanup error handled gracefully')
      return
    }
    console.error('DCVErrorBoundary caught an error:', error, errorInfo)
  }

  render() {
    if (this.state.hasError) {
      return (
        <div style={{ padding: '20px', textAlign: 'center' }}>
          <h2>Something went wrong with the DCV viewer.</h2>
          <button onClick={() => this.setState({ hasError: false })}>
            Try again
          </button>
        </div>
      )
    }

    return this.props.children
  }
}

interface DCVViewerProps {
  presignedUrl: string
  sessionId: string
  runId: string
  onReleaseControl?: () => Promise<void>
  onDisconnect?: (reason: { message: string; code: number }) => void
}

let auth: any
let authInProgress = false

// Global connection registry to prevent duplicate connections in React Strict Mode
const connectionRegistry = new Map<string, { connection: any, timestamp: number }>()

const getOrCreateConnection = (sessionId: string, createFn: () => Promise<any>): Promise<any> => {
  const existing = connectionRegistry.get(sessionId)
  const now = Date.now()
  
  console.log('getOrCreateConnection called for session:', sessionId, 'existing:', !!existing, 'registry size:', connectionRegistry.size)
  
  // If we have a recent connection (less than 5 seconds old), reuse it
  if (existing && (now - existing.timestamp) < 5000) {
    console.log('Reusing existing connection for session:', sessionId, 'age:', now - existing.timestamp, 'ms')
    return Promise.resolve(existing.connection)
  }
  
  // Clean up old connection if it exists
  if (existing) {
    console.log('Cleaning up old connection for session:', sessionId, 'age:', now - existing.timestamp, 'ms')
    try {
      existing.connection.disconnect()
    } catch (e) {
      console.warn('Error cleaning up old connection:', e)
    }
    connectionRegistry.delete(sessionId)
  }
  
  // Create new connection
  console.log('Creating new connection for session:', sessionId)
  return createFn().then(connection => {
    console.log('New connection created and stored for session:', sessionId)
    connectionRegistry.set(sessionId, { connection, timestamp: now })
    return connection
  })
}

const cleanupConnection = (sessionId: string) => {
  const existing = connectionRegistry.get(sessionId)
  console.log('cleanupConnection called for session:', sessionId, 'existing:', !!existing, 'registry size:', connectionRegistry.size)
  if (existing) {
    try {
      console.log('Disconnecting and removing connection for session:', sessionId)
      existing.connection.disconnect()
    } catch (e) {
      console.warn('Error during connection cleanup:', e)
    }
    connectionRegistry.delete(sessionId)
    console.log('Connection removed from registry, new size:', connectionRegistry.size)
  } else {
    console.log('No connection found in registry for session:', sessionId)
  }
}

// DCV Viewer Component that uses DCV SDK directly (like clean viewer)
interface DCVViewerComponentProps {
  sessionId: string
  authToken: string
  serverUrl: string
  onTakeControl: () => void
  onReleaseControl?: () => Promise<void>
  onDisconnect?: (reason: { message: string; code: number }) => void
}

function DCVViewerComponent({ sessionId, authToken, serverUrl, onTakeControl, onReleaseControl, onDisconnect }: DCVViewerComponentProps) {
  const viewerRef = React.useRef(null);
  const [connection, setConnection] = React.useState<any>(null);
  const [status, setStatus] = React.useState('Initializing...');
  const [loading, setLoading] = React.useState(true);
  const [desiredWidth, setDesiredWidth] = React.useState(1600);
  const [desiredHeight, setDesiredHeight] = React.useState(900);
  const [actualWidth, setActualWidth] = React.useState(0);
  const [actualHeight, setActualHeight] = React.useState(0);
  const displayLayoutRequestedRef = React.useRef(false);

  // Override removeChild to prevent DCV DOM conflicts
  React.useEffect(() => {
    const originalRemoveChild = Element.prototype.removeChild;
    
    Element.prototype.removeChild = function(child: Node) {
      try {
        if (this.contains(child)) {
          return originalRemoveChild.call(this, child);
        } else {
          console.log('Prevented removeChild error - child not found in parent');
          return child;
        }
      } catch (e) {
        console.log('Safely handled removeChild error:', e);
        return child;
      }
    };

    return () => {
      Element.prototype.removeChild = originalRemoveChild;
    };
  }, []);

  // Debug: Monitor DCV display content
  React.useEffect(() => {
    const interval = setInterval(() => {
      const displayDiv = document.getElementById('dcv-display');
      if (displayDiv && displayDiv.children.length > 0) {
        console.log('DCV display has content:', {
          children: displayDiv.children.length,
          innerHTML: displayDiv.innerHTML.substring(0, 200) + '...',
          canvases: displayDiv.querySelectorAll('canvas').length
        });
        
        // Check canvas visibility
        const canvases = displayDiv.querySelectorAll('canvas');
        canvases.forEach((canvas, i) => {
          const rect = canvas.getBoundingClientRect();
          console.log(`Canvas ${i} visibility:`, {
            width: canvas.width,
            height: canvas.height,
            display: canvas.style.display,
            visibility: canvas.style.visibility,
            opacity: canvas.style.opacity,
            boundingRect: rect,
            isVisible: rect.width > 0 && rect.height > 0
          });
        });
        
        clearInterval(interval); // Stop checking once we find content
      }
    }, 1000);

    return () => clearInterval(interval);
  }, []);

  const initialLayoutSetRef = React.useRef(false);

  React.useEffect(() => {
    let isActive = true;
    let conn = null;
    
    const initViewer = async () => {
      try {
        if (!isActive) return;
        
        setStatus('Loading DCV SDK...');
        
        // Wait for DCV SDK to be available
        let attempts = 0;
        while (typeof window.dcv === 'undefined' && attempts < 50) {
          await new Promise(resolve => setTimeout(resolve, 100));
          attempts++;
          if (!isActive) return;
        }
        
        if (typeof window.dcv === 'undefined') {
          throw new Error('DCV SDK failed to load');
        }
        
        if (!isActive) return;
        
        // Check if we already have a connection for this session
        const existingConnection = connectionRegistry.get(sessionId)
        if (existingConnection && (Date.now() - existingConnection.timestamp) < 5000) {
          console.log('Using existing connection for session:', sessionId)
          setConnection(existingConnection.connection)
          setLoading(false)
          setStatus('✅ Connected to live session')
          return
        }
        
        setStatus('Connecting to browser session...');
        
        // Set log level
        if (window.dcv.setLogLevel && window.dcv.LogLevel) {
          window.dcv.setLogLevel(window.dcv.LogLevel.INFO);
        }
        
        // Use global connection registry to prevent duplicates in React Strict Mode
        conn = await getOrCreateConnection(sessionId, async () => {
          return await window.dcv.connect({
          url: serverUrl,
          sessionId: sessionId,
          authToken: authToken,
          divId: 'dcv-display',
          
          // AgentCore-specific settings
          clientHiDpiScaling: false,
          enableClientResize: true,
          enableClientViewportResize: true,
          
          observers: {
            httpExtraSearchParams: (method: string, url: string, body: any) => {
              try {
                const parsedUrl = new URL(serverUrl);
                return parsedUrl.searchParams;
              } catch (error) {
                console.error('Failed to extract auth params:', error);
                return new URLSearchParams();
              }
            },
            displayLayout: (serverWidth: number, serverHeight: number, heads: any) => {
              if (!isActive) return;
              console.log(`Display layout received: ${serverWidth}x${serverHeight}`);
              
              // Update actual dimensions
              setActualWidth(serverWidth);
              setActualHeight(serverHeight);
              
              // Only request a larger size ONCE if we get a small default size
              if (conn && !initialLayoutSetRef.current && serverWidth > 0 && serverHeight > 0) {
                // If server gives us a small size (like 800x600), request a better one
                if (serverWidth <= 800 || serverHeight <= 600) {
                  console.log(`Server gave small size (${serverWidth}x${serverHeight}), requesting ${desiredWidth}x${desiredHeight}`);
                  initialLayoutSetRef.current = true;
                  
                  setTimeout(() => {
                    if (!isActive) return;
                    try {
                      conn.requestDisplayLayout([{
                        name: "Main Display",
                        rect: {
                          x: 0,
                          y: 0,
                          width: desiredWidth,
                          height: desiredHeight
                        },
                        primary: true
                      }]);
                    } catch (error) {
                      console.error('Failed to request better display layout:', error);
                    }
                  }, 300);
                } else {
                  // Server gave us a good size, don't request anything
                  initialLayoutSetRef.current = true;
                }
              }
              
              setStatus(`✅ Display: ${serverWidth}×${serverHeight}`);
            },
            firstFrame: () => {
              if (!isActive) return;
              console.log('First frame received!');
              setLoading(false);
              setStatus('✅ Connected to live session');
              
              // Force clear the loading overlay and ensure canvas visibility
              setTimeout(() => {
                const displayDiv = document.getElementById('dcv-display');
                if (displayDiv) {
                  // Remove any loading overlays
                  const loadingElements = displayDiv.querySelectorAll('[style*="position: absolute"]');
                  loadingElements.forEach(el => {
                    if (el.textContent?.includes('Connecting') || el.textContent?.includes('🔄')) {
                      el.remove();
                    }
                  });
                  
                  // Ensure DCV canvas is visible
                  const canvases = displayDiv.querySelectorAll('canvas');
                  canvases.forEach(canvas => {
                    canvas.style.display = 'block';
                    canvas.style.visibility = 'visible';
                    canvas.style.opacity = '1';
                  });
                  
                  console.log('Cleared loading overlay, canvases found:', canvases.length);
                  
                  // If no canvases in our div, search the entire document
                  if (canvases.length === 0) {
                    const allCanvases = document.querySelectorAll('canvas');
                    console.log('Total canvases in document:', allCanvases.length);
                    allCanvases.forEach((canvas, i) => {
                      console.log(`Canvas ${i}:`, {
                        parent: canvas.parentElement?.id || canvas.parentElement?.className,
                        width: canvas.width,
                        height: canvas.height,
                        style: canvas.style.cssText
                      });
                      
                      // If we find a DCV canvas outside our div, move it in
                      if (canvas.width > 0 && canvas.height > 0 && !displayDiv.contains(canvas)) {
                        console.log('Moving external canvas into dcv-display div');
                        displayDiv.appendChild(canvas);
                      }
                    });
                  }
                }
              }, 100);
            },
            error: (error: any) => {
              if (!isActive) return;
              console.error('Connection error:', error);
              setStatus(`❌ Error: ${error.message}`);
              setLoading(false);
              if (onDisconnect) {
                onDisconnect({ message: error.message, code: error.code });
              }
            },
            disconnect: () => {
              if (!isActive) return;
              console.log('DCV connection disconnected');
              setStatus('❌ Disconnected');
              setLoading(false);
              if (onDisconnect) {
                onDisconnect({ message: 'Connection closed', code: 1000 });
              }
            }
          }
        })
        })
        
        if (!isActive) {
          // Component unmounted during connection, clean up
          if (conn) {
            try {
              conn.disconnect();
            } catch (e) {
              console.warn('Error disconnecting during cleanup:', e);
            }
          }
          return;
        }
        
        console.log('Connection established:', conn);
        setConnection(conn);
        
      } catch (error: any) {
        if (!isActive) return;
        console.error('Failed to initialize viewer:', error);
        setStatus(`❌ Error: ${error.message}`);
        setLoading(false);
        if (onDisconnect) {
          onDisconnect({ message: error.message, code: 0 });
        }
      }
    };
    
    if (sessionId && authToken && serverUrl) {
      initViewer();
    }
    
    // Cleanup function
    return () => {
      console.log('DCVViewerComponent cleanup called, isActive:', isActive, 'conn:', !!conn, 'sessionId:', sessionId);
      isActive = false;
      
      // Don't cleanup connections that are fresh in the registry (React Strict Mode protection)
      const existing = connectionRegistry.get(sessionId);
      if (existing && (Date.now() - existing.timestamp) < 5000) {
        console.log('Skipping cleanup of fresh connection (React Strict Mode protection), age:', Date.now() - existing.timestamp, 'ms');
        return;
      }
      
      if (conn) {
        try {
          console.log('Cleaning up DCV connection...');
          // Use global cleanup to prevent issues with React Strict Mode
          cleanupConnection(sessionId);
        } catch (e) {
          console.warn('Error during connection cleanup:', e);
        }
      }
      // Don't clear the display div at all - let DCV handle its own cleanup
      // This prevents React/DCV DOM conflicts that cause removeChild errors
      console.log('Skipping display div cleanup to prevent DOM conflicts');
    };
  }, [sessionId, authToken, serverUrl]);

  // Function to change display size
  const setDisplaySize = (width: number, height: number) => {
    setDesiredWidth(width);
    setDesiredHeight(height);
    
    if (connection && typeof connection.requestDisplayLayout === 'function') {
      console.log(`Manual display size change: ${width}x${height}`);
      try {
        connection.requestDisplayLayout([{
          name: "Main Display",
          rect: {
            x: 0,
            y: 0,
            width: width,
            height: height
          },
          primary: true
        }]);
        setStatus(`🔄 Requesting ${width}×${height}...`);
      } catch (error) {
        console.error('Failed to set display size:', error);
        setStatus(`❌ Failed to set ${width}×${height}`);
      }
    } else {
      console.warn('Connection not available for display size change');
      setStatus(`⚠️ Not connected - cannot set ${width}×${height}`);
    }
  };

  return (
    <div style={{ height: '100vh', display: 'flex', flexDirection: 'column' }} suppressHydrationWarning={true}>
      {/* Header with controls */}
      <div style={{
        backgroundColor: '#232f3e',
        color: 'white',
        padding: '15px 20px',
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'center',
        borderBottom: '1px solid #34495e'
      }}>
        <div style={{ fontSize: '18px', fontWeight: '500' }}>
          🖥️ React DCV Viewer - Session: {sessionId}
        </div>
        <div style={{ display: 'flex', gap: '10px', alignItems: 'center' }}>
          <button
            onClick={onTakeControl}
            style={{
              padding: '8px 16px',
              backgroundColor: '#28a745',
              color: 'white',
              border: 'none',
              borderRadius: '4px',
              cursor: 'pointer',
              fontSize: '14px'
            }}
          >
            🎮 Take Control
          </button>
          <button
            onClick={onReleaseControl}
            style={{
              padding: '8px 16px',
              backgroundColor: '#dc3545',
              color: 'white',
              border: 'none',
              borderRadius: '4px',
              cursor: 'pointer',
              fontSize: '14px'
            }}
          >
            🚫 Release Control
          </button>
          
          <div style={{ borderLeft: '1px solid #34495e', paddingLeft: '10px', marginLeft: '10px' }}>
            <span style={{ fontSize: '12px', marginRight: '8px' }}>Display:</span>
            <button
                onClick={() => setDisplaySize(1600, 900)}
              style={{
                padding: '6px 12px',
                backgroundColor: desiredWidth === 1600 && desiredHeight === 900 ? '#007bff' : '#6c757d',
                color: 'white',
                border: 'none',
                borderRadius: '3px',
                cursor: 'pointer',
                fontSize: '12px',
                marginRight: '5px'
              }}
              >
                1600×900
            </button>
            <button
                onClick={() => setDisplaySize(1920, 1080)}
              style={{
                padding: '6px 12px',
                backgroundColor: desiredWidth === 1920 && desiredHeight === 1080 ? '#007bff' : '#6c757d',
                color: 'white',
                border: 'none',
                borderRadius: '3px',
                cursor: 'pointer',
                fontSize: '12px',
                marginRight: '5px'
              }}
              >
                1920×1080
            </button>
            <button
              onClick={() => setDisplaySize(2560, 1440)}
              style={{
                padding: '6px 12px',
                backgroundColor: desiredWidth === 2560 && desiredHeight === 1440 ? '#007bff' : '#6c757d',
                color: 'white',
                border: 'none',
                borderRadius: '3px',
                cursor: 'pointer',
                fontSize: '12px'
              }}
            >
              2560×1440
            </button>
          </div>
        </div>
      </div>

      {/* DCV Display Area */}
      <div style={{ flex: 1, position: 'relative', backgroundColor: '#000' }}>
        <div
          id="dcv-display"
          style={{
            width: '100%',
            height: '100%',
            position: 'relative',
            overflow: 'visible',
            zIndex: 1,
            display: 'block',
            minHeight: '400px',
            border: '1px solid #333' // Debug border to see the container
          }}
          suppressHydrationWarning={true}
        >
          {loading && (
            <div style={{
              position: 'absolute',
              top: '50%',
              left: '50%',
              transform: 'translate(-50%, -50%)',
              textAlign: 'center',
              color: 'white',
              fontSize: '18px'
            }}>
              🔄 {status}
            </div>
          )}
        </div>
      </div>

      {/* Status indicator */}
      <div style={{
        position: 'fixed',
        bottom: '20px',
        right: '20px',
        background: 'rgba(0,0,0,0.8)',
        color: 'white',
        padding: '10px 15px',
        borderRadius: '5px',
        fontSize: '14px'
      }}>
        {status}
      </div>
    </div>
  );
}

// Main DCVViewer component - handles authentication then renders DCVViewerComponent (EXACTLY like App.js)
export function DCVViewer({
  presignedUrl,
  sessionId,
  runId,
  onReleaseControl,
  onDisconnect
}: DCVViewerProps) {
  const [authenticated, setAuthenticated] = React.useState(false);
  const [dcvSessionId, setDcvSessionId] = React.useState('');
  const [authToken, setAuthToken] = React.useState('');
  const [credentials, setCredentials] = React.useState<Record<string, string>>({});
  const [error, setError] = React.useState('');
  const [loading, setLoading] = React.useState(true);

  const bgColor = useColorModeValue('gray.50', 'gray.900')

  // Add global error handler for unhandled errors
  React.useEffect(() => {
    const handleError = (event: any) => {
      const error = event.error
      const message = error?.message || String(error)
      
      // Suppress harmless DOM cleanup errors from DCV/React conflicts
      if (message.includes('removeChild') || 
          message.includes('Cannot read properties of null') ||
          message.includes('The node to be removed is not a child')) {
        console.log('Suppressed harmless DOM cleanup error:', message)
        event.preventDefault()
        return true
      }
      
      console.error('Unhandled error:', error);
      // Don't disconnect for every error, but log them
    };

    const handleUnhandledRejection = (event: any) => {
      console.error('Unhandled promise rejection:', event.reason);
      // Don't disconnect for every rejection, but log them
    };

    window.addEventListener('error', handleError);
    window.addEventListener('unhandledrejection', handleUnhandledRejection);

    return () => {
      window.removeEventListener('error', handleError);
      window.removeEventListener('unhandledrejection', handleUnhandledRejection);
    };
  }, []);

  // Authentication effect - start authentication with presigned URL prop
  React.useEffect(() => {
    let isActive = true

    const startAuthentication = async () => {
      if (!presignedUrl || authenticated || !isActive) return

      try {
        setLoading(true)
        setError('')

        // Wait for DCV SDK to be available (like the working App.js connection logic)
        let attempts = 0
        while (typeof window.dcv === 'undefined' && attempts < 50) {
          await new Promise(resolve => setTimeout(resolve, 100))
          attempts++
          if (!isActive) return
        }

        if (typeof window.dcv === 'undefined') {
          throw new Error('DCV SDK failed to load')
        }

        if (!isActive) return

        console.log("Starting authentication with URL:", presignedUrl)
        console.log("DCV SDK available:", typeof window.dcv !== 'undefined')
        console.log("Authentication state:", { authenticated, loading })
        authenticate(presignedUrl)

      } catch (error: any) {
        if (!isActive) return
        console.error('Failed to start authentication:', error)
        setError(`Authentication setup failed: ${error.message}`)
        setLoading(false)
      }
    }

    startAuthentication()

    return () => {
      isActive = false
      // Clean up any ongoing authentication
      if (auth && auth.close) {
        try {
          auth.close()
        } catch (e) {
          console.warn('Error during auth cleanup:', e)
        }
      }
    }
  }, [presignedUrl, authenticated])

  const onSuccess = (_: any, result: any) => {
    console.log("Authentication successful:", result);
    authInProgress = false
    
    if (result && result.length > 0) {
      const { sessionId, authToken } = result[0];
      
      console.log("Session ID:", sessionId);
      console.log("Auth Token:", authToken ? "Present" : "Missing");

      setDcvSessionId(sessionId);
      setAuthToken(authToken);
      setAuthenticated(true);
      setCredentials({});
      setError('');
      setLoading(false);
    } else {
      console.error("No session data in auth result");
      setError("No session data received from server");
      setLoading(false);
    }
  }

  const onPromptCredentials = (_: any, credentialsChallenge: any) => {
    console.log("Credentials requested:", credentialsChallenge);
    let requestedCredentials = {};

    credentialsChallenge.requiredCredentials.forEach((challenge: any) => {
      (requestedCredentials as any)[challenge.name] = "";
    });
    
    setCredentials(requestedCredentials);
    setLoading(false);
  }

  const onError = (_: any, error: any) => {
    authInProgress = false
    
    // If we already have a working connection, ignore authentication errors
    if (connectionRegistry.size > 0) {
      const connections = Array.from(connectionRegistry.values());
      const recentConnection = connections.find(conn => (Date.now() - conn.timestamp) < 10000);
      if (recentConnection) {
        console.log("Ignoring authentication error - connection already working");
        // Clear any existing error state since connection is working
        setError('');
        setLoading(false);
        return;
      }
    }
    
    // Only log error if we don't have a working connection
    console.error("Error during authentication:", error);
    
    // Handle empty error objects
    let errorMessage = 'Unknown authentication error'
    if (error && error.message) {
      errorMessage = error.message
    } else if (error && typeof error === 'string') {
      errorMessage = error
    } else if (error && error.code) {
      errorMessage = `Authentication error (code: ${error.code})`
    }
    
    // Don't set error state if connection is working - just return early
    setError(`Authentication failed: ${errorMessage}`);
    setLoading(false);
    
    if (onDisconnect) {
      onDisconnect({ message: errorMessage, code: error?.code || 8 })
    }
  }

  const authenticate = (presignedUrl: string) => {
    console.log("authenticate() called with:", { presignedUrl: presignedUrl?.substring(0, 100) + '...', authenticated, loading })
    
    if (!presignedUrl) {
      console.error("No presigned URL provided");
      setError("No presigned URL provided");
      setLoading(false);
      return;
    }

    if (authenticated) {
      console.log("Already authenticated, skipping");
      return;
    }

    if (authInProgress) {
      console.log("Authentication already in progress, skipping");
      return;
    }

    // Check if we already have any working connection (React Strict Mode protection)
    if (connectionRegistry.size > 0) {
      const connections = Array.from(connectionRegistry.values());
      const recentConnection = connections.find(conn => (Date.now() - conn.timestamp) < 10000);
      if (recentConnection) {
        console.log("Recent connection exists, skipping duplicate authentication");
        return;
      }
    }

    if (typeof window.dcv === 'undefined') {
      console.error("DCV SDK not available");
      setError("DCV SDK not available");
      setLoading(false);
      return;
    }

    console.log("Starting authentication with URL:", presignedUrl.substring(0, 100) + '...');
    
    authInProgress = true
    
    try {
      if (window.dcv.setLogLevel && window.dcv.LogLevel) {
        window.dcv.setLogLevel(window.dcv.LogLevel.INFO);
      }

      auth = window.dcv.authenticate(
        presignedUrl,
        {
          // Extract auth params from presigned URL
          httpExtraSearchParams: (method: string, url: string, body: any) => {
            try {
              const parsedUrl = new URL(presignedUrl);
              return parsedUrl.searchParams;
            } catch (error) {
              console.error('Failed to extract auth params:', error);
              return new URLSearchParams();
            }
          },
          promptCredentials: onPromptCredentials,
          error: onError,
          success: onSuccess
        }
      );
    } catch (err: any) {
      console.error("Failed to start authentication:", err);
      authInProgress = false
      setError(`Authentication setup failed: ${err?.message || 'Unknown error'}`);
      setLoading(false);
      if (onDisconnect) {
        onDisconnect({ message: err?.message || 'Authentication setup failed', code: err?.code || 8 })
      }
    }
  }

  const updateCredentials = (e: any) => {
    const { name, value } = e.target;
    setCredentials({
      ...credentials,
      [name]: value
    });
  }

  const submitCredentials = (e: any) => {
    e.preventDefault();
    if (auth) {
      console.log("Submitting credentials:", Object.keys(credentials));
      auth.sendCredentials(credentials);
      setLoading(true);
    }
  }

  const handleDisconnect = (reason: any) => {
    console.log("Disconnected:", reason.message, "(code:", reason.code, ")");
    setAuthenticated(false);
    setError(`Disconnected: ${reason.message}`);
    
    // Attempt to retry authentication
    if (auth && auth.retry) {
      console.log("Attempting to retry authentication...");
      auth.retry();
      setLoading(true);
    }
  }

  const handleTakeControl = async () => {
    try {
      const response = await fetch('/api/take-control', { method: 'POST' });
      const data = await response.json();
      
      if (data.status === 'success') {
        console.log("Control taken successfully");
      } else {
        console.error("Failed to take control:", data.message);
      }
    } catch (error) {
      console.error("Error taking control:", error);
    }
  }

  const handleReleaseControl = async () => {
    try {
      const response = await fetch('/api/release-control', { method: 'POST' });
      const data = await response.json();
      
      if (data.status === 'success') {
        console.log("Control released successfully");
      } else {
        console.error("Failed to release control:", data.message);
      }
    } catch (error) {
      console.error("Error releasing control:", error);
    }
  }

  // Loading state during authentication
  if (loading) {
    return (
      <Box minH="100vh" bg={bgColor}>
        <VStack spacing={8} align="center" justify="center" minH="100vh">
          <Spinner size="xl" />
          <Text fontSize="xl">🔄 Connecting to AgentCore Browser...</Text>
          <Text fontSize="md" opacity={0.8}>Authenticating with DCV server...</Text>
        </VStack>
      </Box>
    )
  }

  // Error state - but ignore if connection is working
  if (error && !authenticated && connectionRegistry.size === 0) {
    return (
      <Box h="100vh" bg={bgColor} p={4}>
        <VStack spacing={6} align="center" justify="center" minH="100vh">
          <Alert status="error" borderRadius="md" maxW="600px">
            <AlertIcon />
            <Box>
              <AlertTitle>❌ Connection Failed</AlertTitle>
              <AlertDescription>{error}</AlertDescription>
            </Box>
          </Alert>
          <Button 
            onClick={() => window.location.reload()} 
            colorScheme="blue"
            size="lg"
          >
            🔄 Retry Connection
          </Button>
        </VStack>
      </Box>
    )
  }

  // Credentials form (if needed) - but skip if connection is already working
  if (Object.keys(credentials).length > 0 && !authenticated && connectionRegistry.size === 0) {
    return (
      <Box minH="100vh" bg={bgColor}>
        <VStack spacing={8} align="center" justify="center" minH="100vh">
          <Box bg="gray.800" p={8} borderRadius="md" minW="300px">
            <Text fontSize="xl" textAlign="center" mb={6}>🔐 Authentication Required</Text>
            <form onSubmit={submitCredentials}>
              <VStack spacing={4}>
                {Object.keys(credentials).map((cred) => (
                  <Box key={cred} w="100%">
                    <Text mb={2} textTransform="capitalize">{cred}:</Text>
                    <input
                      name={cred}
                      placeholder={`Enter ${cred}`}
                      type={cred === "password" ? "password" : "text"}
                      onChange={updateCredentials}
                      value={credentials[cred]}
                      style={{
                        width: '100%',
                        padding: '10px',
                        border: '1px solid #555',
                        borderRadius: '4px',
                        backgroundColor: '#2c3e50',
                        color: 'white',
                        fontSize: '16px'
                      }}
                    />
                  </Box>
                ))}
                <Button
                  type="submit"
                  colorScheme="blue"
                  w="100%"
                  size="lg"
                  mt={4}
                >
                  🚀 Connect
                </Button>
              </VStack>
            </form>
        </Box>
        </VStack>
      </Box>
    )
  }

  // Main DCV Viewer - render DCVViewerComponent after authentication succeeds
  if (authenticated && dcvSessionId && authToken) {
    return (
      <DCVErrorBoundary>
        <DCVViewerComponent 
          sessionId={dcvSessionId} 
          authToken={authToken} 
          serverUrl={presignedUrl}
          onTakeControl={() => {}} // Not used in our case
          onReleaseControl={onReleaseControl}
          onDisconnect={onDisconnect}
        />
      </DCVErrorBoundary>
    );
  }

  // Fallback
  return (
    <Box minH="100vh" bg={bgColor}>
      <VStack spacing={8} align="center" justify="center" minH="100vh">
        <Text>🔄 Initializing...</Text>
      </VStack>
    </Box>
  )
}
