import React, { useRef } from 'react';
import { StyleSheet, View, Text, Dimensions } from 'react-native';
import { WebView } from 'react-native-webview';

export default function BilingualReader({ bookSlug, page, serverUrl, token }) {
  const enWebViewRef = useRef(null);
  const viWebViewRef = useRef(null);
  
  // Base URLs for the English and Vietnamese rendered HTML files
  const padPage = String(page).padStart(4, '0');
  const enUrl = `${serverUrl}/books/${bookSlug}/output/en/page_${padPage}.html?token=${token}`;
  const viUrl = `${serverUrl}/books/${bookSlug}/output/vi/page_${padPage}.html?token=${token}`;

  // Injected JS to listen to scroll events and notify RN
  const injectScrollListener = (lang) => `
    (function() {
      var isScrolling = false;
      window.addEventListener('scroll', function() {
        if (!isScrolling) {
          window.ReactNativeWebView.postMessage(JSON.stringify({
            type: 'scroll',
            lang: '${lang}',
            scrollTop: window.pageYOffset || document.documentElement.scrollTop
          }));
        }
      });
      
      // Listen for commands from RN to scroll without triggering loops
      window.addEventListener('message', function(event) {
        try {
          var data = JSON.parse(event.data);
          if (data.type === 'scrollTo') {
            isScrolling = true;
            window.scrollTo(0, data.scrollTop);
            setTimeout(function() { isScrolling = false; }, 50);
          }
        } catch(e) {}
      });
    })();
    true;
  `;

  const handleMessage = (event) => {
    try {
      const data = JSON.parse(event.nativeEvent.data);
      if (data.type === 'scroll') {
        const payload = JSON.stringify({ type: 'scrollTo', scrollTop: data.scrollTop });
        if (data.lang === 'en' && viWebViewRef.current) {
          viWebViewRef.current.postMessage(payload);
        } else if (data.lang === 'vi' && enWebViewRef.current) {
          enWebViewRef.current.postMessage(payload);
        }
      }
    } catch (e) {
      console.warn('Failed parsing WebView message:', e);
    }
  };

  return (
    <View style={styles.container}>
      {/* English Pane */}
      <View style={styles.pane}>
        <View style={styles.header}>
          <Text style={styles.headerText}>ENGLISH (EN)</Text>
        </View>
        <WebView
          ref={enWebViewRef}
          source={{ uri: enUrl }}
          injectedJavaScript={injectScrollListener('en')}
          onMessage={handleMessage}
          style={styles.webview}
          scalesPageToFit={true}
        />
      </View>

      {/* Split Divider */}
      <View style={styles.divider} />

      {/* Vietnamese Pane */}
      <View style={styles.pane}>
        <View style={styles.header}>
          <Text style={styles.headerText}>TIẾNG VIỆT (VI)</Text>
        </View>
        <WebView
          ref={viWebViewRef}
          source={{ uri: viUrl }}
          injectedJavaScript={injectScrollListener('vi')}
          onMessage={handleMessage}
          style={styles.webview}
          scalesPageToFit={true}
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    flexDirection: 'row',
    backgroundColor: '#0f172a',
  },
  pane: {
    flex: 1,
    height: '100%',
  },
  divider: {
    width: 2,
    backgroundColor: 'rgba(255, 255, 255, 0.1)',
    height: '100%',
  },
  header: {
    height: 30,
    backgroundColor: '#1e293b',
    justifyContent: 'center',
    alignItems: 'center',
  },
  headerText: {
    color: '#94a3b8',
    fontSize: 10,
    fontWeight: 'bold',
    letterSpacing: 1,
  },
  webview: {
    flex: 1,
    backgroundColor: '#0f172a',
  },
});
