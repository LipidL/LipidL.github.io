var header = document.querySelector('header');
document.querySelectorAll('nav ul li').forEach(function(el) {
    el.addEventListener('mouseover', function() {
        var imgPath = this.getAttribute('header-img');
        var imgColor = this.getAttribute('header-color');
        // this.style.backgroundImage = 'url("data/images/' + imgPath + '")';
        // this.style.backgroundPosition = 'left';
        // this.style.backgroundSize = 'auto 100%';
        // this.style.backgroundRepeat = 'no-repeat';
        header.style.backgroundImage = 'url("data/images/' + imgPath + '")';
        header.style.backgroundColor = imgColor;
        this.classList.add('hovered');
    });
    el.addEventListener('mouseout', function() {
        header.style.backgroundColor = 'rgba(255, 255, 255, 0.5)';
        header.style.backgroundImage = 'url("data/images/blank.png")';
        this.classList.remove('hovered');
    });
});
