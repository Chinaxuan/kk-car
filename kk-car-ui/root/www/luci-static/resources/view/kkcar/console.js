'use strict';
'require baseclass';

// One shell for every view. Move live nodes, never clone controls or pollers.
var pages = [
    ['kkcar', '行车总览', 'overview', '网络'],
    ['kkcar_connections', '连接设置', 'connections', '网络'],
    ['kkcar_health', '网络守护', 'health', '网络'],
    ['kkcar_dji', '蜂窝与通信', 'cellular', '通信与设备'],
    ['kkcar_ups', '电源与设备', 'power', '通信与设备'],
    ['kkcar_notifications', '通知中心', 'notifications', '管理'],
    ['kkcar_settings', '设置中心', 'settings', '管理']
];
var paths = {
    overview: ['M3 3h7v7H3z', 'M14 3h7v7h-7z', 'M3 14h7v7H3z', 'M14 14h7v7h-7z'],
    connections: ['M5 12h14', 'M8 8l-4 4 4 4', 'M16 8l4 4-4 4'],
    health: ['M12 3l8 3v6c0 5-8 9-8 9s-8-4-8-9V6z', 'M7 12h3l2-4 2 8 2-4h2'],
    cellular: ['M4 20v-4', 'M9 20v-8', 'M14 20V8', 'M19 20V4'],
    power: ['M4 7h15v10H4z', 'M21 10v4', 'M12 9l-3 4h4l-1 3'],
    notifications: ['M6 9a6 6 0 0112 0v7l2 2H4l2-2z', 'M10 21h4'],
    settings: ['M4 6h16', 'M4 12h16', 'M4 18h16', 'M8 4v4', 'M16 10v4', 'M10 16v4']
};
function icon(name) {
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('aria-hidden', 'true');
    (paths[name] || paths.settings).forEach(function(d) {
        var path = document.createElementNS(svg.namespaceURI, 'path');
        path.setAttribute('d', d); svg.appendChild(path);
    });
    return svg;
}
function sidebar(active) {
    var nav = E('nav', {'class':'kc-nav', 'aria-label':'KK-Car 功能导航'}), group;
    pages.forEach(function(page) {
        if(group !== page[3]) { group = page[3]; nav.appendChild(E('p', {'class':'kc-nav-label'}, group)); }
        nav.appendChild(E('a', {href:L.url('admin/' + page[0]), 'class':'kc-nav-link',
            'aria-current':active === page[0] ? 'page' : null}, [icon(page[2]), E('span', {}, page[1])]));
    });
    return E('aside', {'class':'kc-sidebar', id:'kc-navigation'}, [
        E('a', {href:L.url('admin/kkcar'), 'class':'kc-brand', 'aria-label':'KK-Car 行车总览'}, [
            E('b', {}, 'KK'), E('span', {}, [E('strong', {}, 'KK-CAR'), E('small', {}, '车载控制台')])]),
        nav,
        E('div', {'class':'kc-nav-bottom'}, [
            E('a', {href:L.url('admin/status/overview')}, 'OpenWrt 高级管理 ↗'),
            E('a', {href:L.url('admin/logout')}, '退出登录'),
            E('p', {}, ['Raspberry Pi 3B+', E('br'), '本地服务 · 管理员会话'])])
    ]);
}
return baseclass.extend({
    mount: function(root, options) {
        options = options || {};
        if(!document.getElementById('kk-console-css'))
            document.head.appendChild(E('link', {id:'kk-console-css', rel:'stylesheet',
                href:L.resource('view/kkcar/console.css') + '?v=20260927-console4'}));
        var existingMain = root.querySelector(':scope > .ku-main');
        if(existingMain) root.replaceChildren.apply(root, Array.from(existingMain.children));
        // The shared workspace is the only main landmark. Keep every child and
        // attribute while flattening module-specific layout landmarks.
        Array.from(root.querySelectorAll('main')).forEach(function(node) {
            var content = E('div');
            Array.from(node.attributes).forEach(function(a) { content.setAttribute(a.name, a.value); });
            content.append.apply(content, Array.from(node.childNodes)); node.replaceWith(content);
        });
        var oldHeader = root.querySelector(':scope > .kk-header, :scope > .ku-header');
        var status = options.status || E('span', {'class':'kc-updated'}, '设备数据');
        status.classList.add('kc-updated');
        var actions = E('div', {'class':'kc-header-actions'}, options.actions || []);
        var heading = E('div', {'class':'kc-heading'}, [
            E('div', {'class':'kc-heading-line'}, [E('h1', {}, options.title), options.badge || '']),
            E('p', {}, options.description || '')]);
        if(options.badge) options.badge.setAttribute('role', 'status');
        var shell = E('div', {'class':'kc-shell', 'data-page':options.page});
        var toggle = E('button', {type:'button', 'class':'kc-menu-toggle',
            'aria-label':'展开功能导航', 'aria-controls':'kc-navigation', 'aria-expanded':'false', click:function() {
                var open = shell.classList.toggle('kc-menu-open');
                toggle.setAttribute('aria-expanded', String(open));
                toggle.setAttribute('aria-label', open ? '收起功能导航' : '展开功能导航');
            }}, [E('span', {'aria-hidden':'true'}, '☰'), E('span', {}, '功能')]);
        var header = E('header', {'class':'kc-header'}, [toggle, heading, E('div', {'class':'kc-header-meta'}, [status, actions])]);
        root.classList.add('kc-page');
        if(oldHeader) oldHeader.replaceWith(header); else root.prepend(header);
        if(options.localNav) {
            var local = root.querySelector(options.localNav);
            if(local) {
                local.classList.remove('kk-dji-side-nav');
                local.classList.add('kc-local-nav');
                header.after(local);
                var redundant = root.querySelector('.kk-dji-sidebar');
                if(redundant) redundant.remove();
            }
        }
        var navigation = sidebar(options.page);
        navigation.addEventListener('keydown', function(event) {
            if(event.key === 'Escape') {
                shell.classList.remove('kc-menu-open'); toggle.setAttribute('aria-expanded', 'false');
                toggle.setAttribute('aria-label', '展开功能导航'); toggle.focus();
            }
        });
        shell.append(E('a', {'class':'kc-skip', href:'#kc-workspace'}, '跳到页面内容'), navigation,
            E('main', {'class':'kc-work', id:'kc-workspace', tabindex:'-1'}, [root]));
        return shell;
    }
});
