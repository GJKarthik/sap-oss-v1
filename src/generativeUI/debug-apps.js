// Simple script to test if the Angular apps are loading properly
const http = require('http');
const { exec } = require('child_process');

function checkApp(port, name) {
    return new Promise((resolve) => {
        const req = http.get(`http://localhost:${port}`, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                console.log(`\n=== ${name} (Port ${port}) ===`);
                console.log(`Status: ${res.statusCode}`);
                
                // Check if Angular app structure is present
                if (data.includes('ui-angular-root') || data.includes('app-root')) {
                    console.log('Angular structure: FOUND');
                } else {
                    console.log('Angular structure: NOT FOUND');
                }
                
                // Check if JavaScript files are referenced
                if (data.includes('main.js') && data.includes('runtime.js')) {
                    console.log('JavaScript files: FOUND');
                } else {
                    console.log('JavaScript files: NOT FOUND');
                }
                
                // Check for common error patterns
                if (data.includes('error') || data.includes('Error')) {
                    console.log('Error indicators: FOUND');
                } else {
                    console.log('Error indicators: NOT FOUND');
                }
                
                resolve({ port, name, status: res.statusCode, success: true });
            });
        });
        
        req.on('error', (err) => {
            console.log(`\n=== ${name} (Port ${port}) ===`);
            console.log(`Status: OFFLINE - ${err.message}`);
            resolve({ port, name, status: 0, success: false });
        });
        
        req.setTimeout(5000, () => {
            req.destroy();
            console.log(`\n=== ${name} (Port ${port}) ===`);
            console.log('Status: TIMEOUT');
            resolve({ port, name, status: 0, success: false });
        });
    });
}

async function checkAllApps() {
    console.log('Checking GenerativeUI Applications...');
    
    const apps = [
        { port: 4200, name: 'UI5 Workspace' },
        { port: 4300, name: 'Training Application' },
        { port: 4301, name: 'Training Application (Alt)' }
    ];
    
    for (const app of apps) {
        await checkApp(app.port, app.name);
    }
    
    console.log('\n=== Backend Services ===');
    
    // Check backend services
    const backends = [
        { port: 8000, name: 'Training API' },
        { port: 9160, name: 'MCP Server' }
    ];
    
    for (const backend of backends) {
        await checkApp(backend.port, backend.name);
    }
    
    console.log('\n=== Recommendations ===');
    console.log('1. If Angular structure is FOUND but pages are blank, check browser console for JavaScript errors');
    console.log('2. If JavaScript files are NOT FOUND, the build process may have failed');
    console.log('3. If backend services are OFFLINE, start them with: docker compose up -d');
    console.log('4. Try clearing browser cache and restarting the development servers');
    console.log('5. Check if there are any port conflicts');
}

checkAllApps().catch(console.error);
