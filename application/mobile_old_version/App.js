import React, { useState, useEffect } from 'react';
import { StatusBar } from 'expo-status-bar';
import { StyleSheet, Text, View, TextInput, TouchableOpacity, FlatList, SafeAreaView } from 'react-native';
import BilingualReader from './components/BilingualReader';

const DEFAULT_SERVER_URL = "http://localhost:27099"; // Thay bằng IP của Server Debian khi chạy thật

export default function App() {
  const [serverUrl, setServerUrl] = useState(DEFAULT_SERVER_URL);
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  
  const [token, setToken] = useState(null);
  const [books, setBooks] = useState([]);
  const [activeBook, setActiveBook] = useState(null);
  const [page, setPage] = useState(1);
  const [errorMsg, setErrorMsg] = useState('');
  const [isFullScreen, setIsFullScreen] = useState(false);

  // Handle Login
  const handleLogin = async () => {
    setErrorMsg('');
    try {
      const url = `${serverUrl}/api/auth/login?username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`;
      const response = await fetch(url, { method: 'POST' });
      if (!response.ok) {
        throw new Error('Sai tài khoản hoặc mật khẩu');
      }
      const data = await response.json();
      setToken(data.access_token);
    } catch (e) {
      setErrorMsg(e.message || 'Lỗi kết nối Server');
    }
  };

  // Load books on login token
  useEffect(() => {
    if (token) {
      fetchBooks();
    }
  }, [token]);

  const fetchBooks = async () => {
    try {
      const response = await fetch(`${serverUrl}/api/books`, {
        headers: { 'Authorization': `Bearer ${token}` }
      });
      const data = await response.json();
      // Reverse so newest books (added later) appear first
      setBooks([...data].reverse());
    } catch (e) {
      console.error('Failed to fetch books:', e);
    }
  };

  // Login Screen Render
  if (!token) {
    return (
      <SafeAreaView style={styles.loginContainer}>
        <StatusBar style="light" />
        <Text style={styles.logoTitle}>Bilingual Library</Text>
        <Text style={styles.logoSubtitle}>Đăng nhập để đồng bộ tủ sách song ngữ của bạn</Text>

        <View style={styles.form}>
          <TextInput
            style={styles.input}
            placeholder="IP Server (ví dụ: http://192.168.1.5:27099)"
            placeholderTextColor="#64748b"
            value={serverUrl}
            onChangeText={setServerUrl}
            autoCapitalize="none"
          />
          <TextInput
            style={styles.input}
            placeholder="Tên tài khoản"
            placeholderTextColor="#64748b"
            value={username}
            onChangeText={setUsername}
            autoCapitalize="none"
          />
          <TextInput
            style={styles.input}
            placeholder="Mật khẩu"
            placeholderTextColor="#64748b"
            secureTextEntry
            value={password}
            onChangeText={setPassword}
          />
          
          {errorMsg ? <Text style={styles.errorText}>{errorMsg}</Text> : null}

          <TouchableOpacity style={styles.loginBtn} onPress={handleLogin}>
            <Text style={styles.loginBtnText}>Đăng nhập</Text>
          </TouchableOpacity>
        </View>
      </SafeAreaView>
    );
  }

  // Reader Screen Render
  if (activeBook) {
    return (
      <SafeAreaView style={styles.container}>
        <StatusBar style="light" hidden={isFullScreen} />
        
        {/* Navigation Bar */}
        {!isFullScreen && (
          <View style={styles.navBar}>
            <TouchableOpacity style={styles.backBtn} onPress={() => { setActiveBook(null); setIsFullScreen(false); }}>
              <Text style={styles.backBtnText}>✕ Đóng</Text>
            </TouchableOpacity>
            <Text style={styles.navTitle} numberOfLines={1}>{activeBook.title}</Text>
            <View style={styles.navRight}>
              <Text style={styles.navPages}>Trang {page} / {activeBook.pageCount}</Text>
              <TouchableOpacity style={styles.fullScreenBtn} onPress={() => setIsFullScreen(true)}>
                <Text style={styles.fullScreenBtnText}>⤢</Text>
              </TouchableOpacity>
            </View>
          </View>
        )}

        {/* The Bilingual split view reader */}
        <BilingualReader
          bookSlug={activeBook.slug}
          page={page}
          serverUrl={serverUrl}
          token={token}
          onToggleFullScreen={() => setIsFullScreen(prev => !prev)}
        />

        {/* Footer pagination */}
        {!isFullScreen && (
          <View style={styles.paginationBar}>
            <TouchableOpacity 
              style={[styles.pageBtn, page <= 1 && styles.pageBtnDisabled]} 
              onPress={() => setPage(p => Math.max(1, p - 1))}
              disabled={page <= 1}
            >
              <Text style={styles.pageBtnText}>◀ Trang Trước</Text>
            </TouchableOpacity>
            
            <TouchableOpacity 
              style={[styles.pageBtn, page >= activeBook.pageCount && styles.pageBtnDisabled]} 
              onPress={() => setPage(p => Math.min(activeBook.pageCount, p + 1))}
              disabled={page >= activeBook.pageCount}
            >
              <Text style={styles.pageBtnText}>Trang Tiếp ▶</Text>
            </TouchableOpacity>
          </View>
        )}
      </SafeAreaView>
    );
  }

  // Dashboard / Library Selection Render
  return (
    <SafeAreaView style={styles.container}>
      <StatusBar style="light" />
      <View style={styles.header}>
        <Text style={styles.headerTitle}>Thư Viện Song Ngữ</Text>
        <TouchableOpacity style={styles.logoutBtn} onPress={() => setToken(null)}>
          <Text style={styles.logoutBtnText}>Đăng xuất</Text>
        </TouchableOpacity>
      </View>

      <FlatList
        data={books}
        keyExtractor={(item) => item.slug}
        contentContainerStyle={styles.listContainer}
        renderItem={({ item }) => (
          <TouchableOpacity 
            style={styles.bookCard}
            onPress={() => {
              setActiveBook(item);
              setPage(1);
            }}
          >
            <View style={styles.bookInfo}>
              <Text style={styles.bookTitle}>{item.title}</Text>
              <Text style={styles.bookAuthor}>{item.author}</Text>
              <Text style={styles.bookPages}>{item.pageCount} trang</Text>
            </View>
            <Text style={styles.readIcon}>📖 Đọc</Text>
          </TouchableOpacity>
        )}
      />
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#0f172a',
  },
  loginContainer: {
    flex: 1,
    backgroundColor: '#0f172a',
    justifyContent: 'center',
    alignItems: 'center',
    padding: 20,
  },
  logoTitle: {
    fontSize: 32,
    fontWeight: '800',
    color: '#6366f1',
    marginBottom: 10,
  },
  logoSubtitle: {
    fontSize: 14,
    color: '#94a3b8',
    textAlign: 'center',
    marginBottom: 30,
    paddingHorizontal: 20,
  },
  form: {
    width: '100%',
    maxWidth: 340,
  },
  input: {
    backgroundColor: '#1e293b',
    borderWidth: 1,
    borderColor: '#334155',
    borderRadius: 8,
    padding: 12,
    color: '#f8fafc',
    marginBottom: 15,
    fontSize: 16,
  },
  errorText: {
    color: '#ef4444',
    marginBottom: 15,
    textAlign: 'center',
  },
  loginBtn: {
    backgroundColor: '#6366f1',
    borderRadius: 8,
    padding: 14,
    alignItems: 'center',
  },
  loginBtnText: {
    color: '#ffffff',
    fontSize: 16,
    fontWeight: '600',
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: 20,
    borderBottomWidth: 1,
    borderBottomColor: '#1e293b',
  },
  headerTitle: {
    fontSize: 24,
    fontWeight: '700',
    color: '#f8fafc',
  },
  logoutBtn: {
    padding: 8,
  },
  logoutBtnText: {
    color: '#64748b',
    fontSize: 14,
  },
  listContainer: {
    padding: 20,
  },
  bookCard: {
    backgroundColor: '#1e293b',
    borderRadius: 12,
    padding: 20,
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 15,
    borderWidth: 1,
    borderColor: '#334155',
  },
  bookInfo: {
    flex: 1,
    marginRight: 10,
  },
  bookTitle: {
    fontSize: 18,
    fontWeight: '600',
    color: '#f8fafc',
    marginBottom: 4,
  },
  bookAuthor: {
    fontSize: 14,
    color: '#94a3b8',
    marginBottom: 8,
  },
  bookPages: {
    fontSize: 12,
    color: '#6366f1',
    fontWeight: '500',
  },
  readIcon: {
    color: '#6366f1',
    fontWeight: '600',
  },
  navBar: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 15,
    height: 50,
    backgroundColor: '#1e293b',
    borderBottomWidth: 1,
    borderBottomColor: '#334155',
  },
  backBtn: {
    padding: 5,
  },
  backBtnText: {
    color: '#f8fafc',
    fontSize: 15,
  },
  navTitle: {
    color: '#f8fafc',
    fontWeight: '600',
    fontSize: 16,
    flex: 1,
    textAlign: 'center',
    marginHorizontal: 10,
  },
  navRight: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  navPages: {
    color: '#94a3b8',
    fontSize: 13,
    marginRight: 15,
  },
  fullScreenBtn: {
    padding: 5,
  },
  fullScreenBtnText: {
    color: '#f8fafc',
    fontSize: 18,
    fontWeight: '600',
  },
  paginationBar: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: 15,
    backgroundColor: '#1e293b',
    borderTopWidth: 1,
    borderTopColor: '#334155',
  },
  pageBtn: {
    backgroundColor: '#6366f1',
    borderRadius: 6,
    paddingVertical: 10,
    paddingHorizontal: 15,
  },
  pageBtnDisabled: {
    backgroundColor: '#475569',
    opacity: 0.5,
  },
  pageBtnText: {
    color: '#ffffff',
    fontWeight: '600',
  },
});
